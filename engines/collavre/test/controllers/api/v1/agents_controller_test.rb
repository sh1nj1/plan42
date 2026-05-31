# frozen_string_literal: true

require "test_helper"

module Collavre
  module Api
    module V1
      class AgentsControllerTest < ActionDispatch::IntegrationTest
        setup do
          @user = users(:one)
          @user.update!(email_verified_at: Time.current)

          @application = Doorkeeper::Application.create!(
            name: "Test Agent Client",
            redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
            scopes: "public",
            owner: @user
          )
          @token = Doorkeeper::AccessToken.create!(
            application: @application,
            resource_owner_id: @user.id,
            scopes: "public"
          )
        end

        # --- Authentication ---

        test "register requires authentication" do
          post "/api/v1/agent/register", params: { name: "test-agent" }, as: :json
          assert_response :unauthorized
        end

        test "register rejects invalid token" do
          post "/api/v1/agent/register",
            params: { name: "test-agent" },
            headers: { "Authorization" => "Bearer invalid" },
            as: :json
          assert_response :unauthorized
        end

        # --- Register ---

        test "register creates single Claude Channel agent and topic" do
          assert_difference -> { User.count }, 1 do
            post "/api/v1/agent/register",
              params: { name: "session-a1b2" },
              headers: auth_headers,
              as: :json
          end

          assert_response :ok
          body = JSON.parse(response.body)

          assert body["agent_id"].present?
          # Per-session agents: name includes session_name so the agent picker
          # shows distinct entries when multiple Claude sessions are running.
          assert_equal "Claude Channel (session-a1b2)", body["agent_name"]
          assert body["topic_id"].present?
          assert_equal "Claude session-a1b2", body["topic_name"]
          assert body["inbox_creative_id"].present?

          ai_user = User.find(body["agent_id"])
          assert_equal "anthropic", ai_user.llm_vendor
          assert_equal "claude-code", ai_user.llm_model
          assert_equal "true", ai_user.routing_expression
          assert_equal @user.id, ai_user.created_by_id
          assert ai_user.ai_user?
          assert ai_user.claude_channel_agent?

          topic = Topic.find(body["topic_id"])
          assert_equal ai_user, topic.primary_agent

          inbox = Creative.find(body["inbox_creative_id"])
          share = CreativeShare.find_by(creative: inbox, user: ai_user)
          assert_not_nil share
          assert_equal "feedback", share.permission

          assert_not Contact.exists?(user: @user, contact_user: ai_user)
        end

        test "register creates distinct agents for concurrent sessions with different names" do
          # Two concurrent Claude Code sessions for the same human must produce
          # two distinct ai_users so each session subscribes to its own
          # agent:user:<id> stream — otherwise both would receive every
          # dispatch routed to the shared agent and produce duplicate replies.
          assert_difference -> { User.count }, 2 do
            post "/api/v1/agent/register",
              params: { name: "session-1" },
              headers: auth_headers,
              as: :json
            assert_response :ok
            post "/api/v1/agent/register",
              params: { name: "session-2" },
              headers: auth_headers,
              as: :json
            assert_response :ok
          end

          users = User.where(created_by_id: @user.id, llm_model: "claude-code").order(:id).last(2)
          assert_equal 2, users.size
          assert_not_equal users[0].id, users[1].id
          assert_equal "Claude Channel (session-1)", users[0].name
          assert_equal "Claude Channel (session-2)", users[1].name
        end

        test "register reuses agent for same session_name (idempotent re-register)" do
          # Same session re-registering (e.g. plugin reconnect) must not
          # proliferate ai_users.
          post "/api/v1/agent/register",
            params: { name: "session-recycle" },
            headers: auth_headers,
            as: :json
          assert_response :ok
          first = JSON.parse(response.body)

          assert_no_difference -> { User.count } do
            post "/api/v1/agent/register",
              params: { name: "session-recycle" },
              headers: auth_headers,
              as: :json
          end
          assert_response :ok
          second = JSON.parse(response.body)

          assert_equal first["agent_id"], second["agent_id"]
          assert_equal first["topic_id"], second["topic_id"]
        end

        test "register rejects when deterministic email is held by foreign-owned User" do
          # Email is human-derivable (claude-channel-<uid>-<slug>@...). If a row
          # with that exact email exists but is owned by someone else, silently
          # reusing it would attach the caller's inbox feedback share to a
          # foreign User and leave AgentChannel#subscribed rejecting the
          # plugin's WS subscription on ownership mismatch.
          other = users(:two)
          slug = "collision"
          email = "claude-channel-#{@user.id}-#{slug}@agent.collavre.local"
          User.create!(
            email: email,
            name: "Squatter",
            password: SecureRandom.hex(32),
            llm_vendor: "anthropic",
            llm_model: "claude-code",
            created_by_id: other.id,
            searchable: false,
            routing_expression: "true"
          )

          assert_no_difference -> { User.count } do
            post "/api/v1/agent/register",
              params: { name: slug },
              headers: auth_headers,
              as: :json
          end
          assert_response :conflict
        end

        test "register rejects when email is held by non-Claude-Channel ai_user" do
          # A row owned by the caller but with a different llm_model (e.g. a
          # Gemini agent previously created with the same email) must not be
          # silently repurposed as a Claude Channel agent.
          slug = "wrongmodel"
          email = "claude-channel-#{@user.id}-#{slug}@agent.collavre.local"
          User.create!(
            email: email,
            name: "Gemini",
            password: SecureRandom.hex(32),
            llm_vendor: "google",
            llm_model: "gemini-1.5-pro",
            created_by_id: @user.id,
            searchable: false,
            routing_expression: "true"
          )

          assert_no_difference -> { User.count } do
            post "/api/v1/agent/register",
              params: { name: slug },
              headers: auth_headers,
              as: :json
          end
          assert_response :conflict
        end

        test "register unarchives prior archived topic with same session name" do
          first = register_agent("recycled-pid")
          first_topic_id = first["topic_id"]

          delete "/api/v1/agent/#{first['agent_id']}",
            params: { topic_id: first_topic_id },
            headers: auth_headers,
            as: :json
          assert_response :no_content
          assert Topic.find(first_topic_id).archived?

          second = register_agent("recycled-pid")
          assert_equal first_topic_id, second["topic_id"],
            "register should reuse the archived topic, not create a new row"
          assert_not Topic.find(first_topic_id).archived?,
            "register should unarchive the reused topic so its comments are visible again"
        end

        test "register requires name" do
          post "/api/v1/agent/register",
            params: { name: "" },
            headers: auth_headers,
            as: :json
          assert_response :unprocessable_entity
        end

        # --- Reply ---

        test "reply creates comment as AI agent" do
          reg = register_agent("reply-test")
          topic_id = reg["topic_id"]

          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "Hello from Claude" },
            headers: auth_headers,
            as: :json

          assert_response :created
          body = JSON.parse(response.body)
          assert body["comment_id"].present?

          comment = Comment.find(body["comment_id"])
          assert_equal "Hello from Claude", comment.content
          assert_equal topic_id, comment.topic_id
          # skip_dispatch is a virtual attribute, verified via agent user
          ai_user = User.find(reg["agent_id"])
          assert_equal ai_user.id, comment.user_id
        end

        test "reply marks delegated task done and links comment" do
          reg = register_agent("delegated-task-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          task = Collavre::Task.create!(
            name: "Response to comment_created",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "Claude responded" },
            headers: auth_headers,
            as: :json
          assert_response :created
          body = JSON.parse(response.body)

          assert_equal "done", task.reload.status
          assert_equal task.id, Comment.find(body["comment_id"]).task_id
        end

        test "reply with task_id completes the specified delegated task" do
          # When topic concurrency > 1, multiple delegated tasks can co-exist
          # in the same topic. Claude may reply to a later dispatch first;
          # task_id correlation must complete the right task, not the oldest.
          reg = register_agent("task-id-correlation-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          older = Collavre::Task.create!(
            name: "Older dispatch",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id,
            created_at: 2.minutes.ago
          )
          newer = Collavre::Task.create!(
            name: "Newer dispatch",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id,
            created_at: 1.minute.ago
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "Reply to newer", task_id: newer.id },
            headers: auth_headers,
            as: :json
          assert_response :created
          body = JSON.parse(response.body)

          assert_equal "done", newer.reload.status, "newer task should be completed"
          assert_equal "delegated", older.reload.status, "older task should remain delegated"
          assert_equal newer.id, Comment.find(body["comment_id"]).task_id
        end

        test "reply with task_id ignored when it does not match a delegated task in this topic" do
          # Foreign or stale task_id must not punch through the scope.
          reg = register_agent("task-id-foreign-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          delegated = Collavre::Task.create!(
            name: "Real delegated task",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "Stale id", task_id: 99_999_999 },
            headers: auth_headers,
            as: :json
          assert_response :created

          assert_equal "delegated", delegated.reload.status,
            "real delegated task must not be completed by a foreign task_id"
        end

        test "reply with task_id authorizes Claude Channel agent on topic where primary_agent diverges" do
          # When the matcher dispatches a Claude Channel agent via
          # routing_expression on a work topic whose primary_agent is unset or
          # a different AI agent, the legacy topic.primary_agent gate would
          # 403 the reply and leak a delegated task. The echoed task_id should
          # authorize the dispatched agent directly.
          reg = register_agent("primary-diverge-test")
          ai_user = User.find(reg["agent_id"])

          # Build a non-inbox creative + topic the agent was matched against,
          # share feedback permission to mimic agent picker selection, and
          # leave primary_agent set to a *different* AI agent (or nil) so the
          # legacy gate would deny.
          creative = Creative.create!(user: @user, description: "Work creative")
          other_agent = users(:ai_bot)
          topic = creative.topics.create!(name: "Work topic", user: @user)
          topic.set_primary_agent!(other_agent)
          CreativeShare.create!(creative: creative, user: ai_user, permission: "feedback")

          task = Collavre::Task.create!(
            name: "Dispatch via routing_expression",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic.id,
            creative_id: creative.id
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic.id, text: "Claude replying via task_id", task_id: task.id },
            headers: auth_headers,
            as: :json
          assert_response :created

          body = JSON.parse(response.body)
          comment = Comment.find(body["comment_id"])
          assert_equal ai_user.id, comment.user_id,
            "comment must be attributed to the dispatched Claude Channel agent, not topic.primary_agent"
          assert_equal task.id, comment.task_id
          assert_equal "done", task.reload.status
        end

        test "reply with task_id refuses when task agent is not owned by current_user" do
          # task_id must not become a back-door to ventriloquize someone else's
          # agent — the resolved agent still has to be owned by the token holder.
          reg = register_agent("task-id-foreign-owner-test")
          topic = Topic.find(reg["topic_id"])
          creative = topic.creative.effective_origin

          other_user = users(:two)
          foreign_agent = User.create!(
            email: "foreign-claude@agent.collavre.local",
            name: "Foreign Claude",
            password: SecureRandom.hex(32),
            llm_vendor: "anthropic",
            llm_model: "claude-code",
            created_by_id: other_user.id
          )
          foreign_task = Collavre::Task.create!(
            name: "Foreign delegated task",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: foreign_agent,
            topic_id: topic.id,
            creative_id: creative.id
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic.id, text: "should not bind", task_id: foreign_task.id },
            headers: auth_headers,
            as: :json

          # Falls through to topic.primary_agent (which is the registering
          # user's Claude Channel agent), so the reply is attributed to that
          # agent — NOT to the foreign agent.
          assert_response :created
          body = JSON.parse(response.body)
          assert_equal reg["agent_id"], Comment.find(body["comment_id"]).user_id
          assert_equal "delegated", foreign_task.reload.status,
            "foreign agent's delegated task must not be completed by this token holder"
        end

        test "reply advances parent workflow when delegated subtask completes" do
          reg = register_agent("workflow-subtask-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          parent_task = Collavre::Task.create!(
            name: "Parent workflow",
            status: "running",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )
          subtask = Collavre::Task.create!(
            name: "Subtask",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id,
            parent_task: parent_task
          )

          completed_with = nil
          executor_stub = lambda { |passed_parent|
            assert_equal parent_task.id, passed_parent.id
            mock = Minitest::Mock.new
            mock.expect(:complete_subtask!, nil) { |t| completed_with = t.id; true }
            mock
          }

          Collavre::Comments::WorkflowExecutor.stub(:new, executor_stub) do
            post "/api/v1/agent/reply",
              params: { topic_id: topic_id, text: "Subtask done" },
              headers: auth_headers,
              as: :json
          end
          assert_response :created

          assert_equal "done", subtask.reload.status
          assert_equal subtask.id, completed_with,
            "WorkflowExecutor#complete_subtask! must be called with the freshly-completed subtask"
        end

        test "reply drains topic queue after delegated task completes" do
          reg = register_agent("dequeue-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          Collavre::Task.create!(
            name: "Delegated",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          called_with = nil
          stub = lambda { |tid, cid = nil| called_with = [ tid, cid ] }

          Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, stub) do
            post "/api/v1/agent/reply",
              params: { topic_id: topic_id, text: "Reply" },
              headers: auth_headers,
              as: :json
          end
          assert_response :created
          assert_equal [ topic_id, creative.id ], called_with
        end

        test "reply releases agent resource slot on delegated completion" do
          reg = register_agent("release-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          task = Collavre::Task.create!(
            name: "Delegated",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          # Simulate the slot the AiAgentJob held under task.id for this Claude
          # Channel run; reply must release it so capacity reflects reality.
          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(task.id)
          assert_equal 1, tracker.active_jobs

          Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(_t, _c) { nil }) do
            post "/api/v1/agent/reply",
              params: { topic_id: topic_id, text: "Reply" },
              headers: auth_headers,
              as: :json
          end
          assert_response :created
          assert_equal 0, Collavre::Orchestration::ResourceTracker.for(ai_user).active_jobs,
            "Expected the delegated task's slot to be released after reply"
        end

        test "reply leaves non-delegated tasks untouched" do
          reg = register_agent("non-delegated-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          running_task = Collavre::Task.create!(
            name: "Running task",
            status: "running",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "Hi" },
            headers: auth_headers,
            as: :json
          assert_response :created

          assert_equal "running", running_task.reload.status
        end

        test "reply dispatches A2A when mentioning another agent" do
          reg = register_agent("a2a-test")
          bot = users(:ai_bot)
          text = "@#{bot.name}: what do you think?"

          dispatcher_args = nil
          mock_new = lambda { |**kwargs|
            dispatcher_args = kwargs
            mock = Minitest::Mock.new
            mock.expect(:dispatch, nil)
            mock
          }

          Collavre::AiAgent::A2aDispatcher.stub(:new, mock_new) do
            post "/api/v1/agent/reply",
              params: { topic_id: reg["topic_id"], text: text },
              headers: auth_headers,
              as: :json
          end

          assert_response :created
          assert_not_nil dispatcher_args, "A2aDispatcher should have been instantiated"
          assert_equal reg["agent_id"], dispatcher_args[:agent].id
          assert_equal text, dispatcher_args[:reply_comment].content
        end

        test "reply checks creative permission" do
          reg = register_agent("perm-test")
          topic = Topic.find(reg["topic_id"])

          # Revoke permission by removing the user's ownership
          creative = topic.creative.effective_origin
          other_user = users(:two)
          creative.update!(user: other_user)
          # Clear any shares for current user
          CreativeShare.where(creative: creative, user: @user).destroy_all

          post "/api/v1/agent/reply",
            params: { topic_id: topic.id, text: "Should fail" },
            headers: auth_headers,
            as: :json

          assert_response :forbidden
        end

        test "reply rejects missing topic" do
          post "/api/v1/agent/reply",
            params: { topic_id: 999_999, text: "nope" },
            headers: auth_headers,
            as: :json
          assert_response :not_found
        end

        test "reply rejects unauthorized agent" do
          reg = register_agent("auth-test")
          topic = Topic.find(reg["topic_id"])

          # Create a different user with their own token
          other_user = users(:two)
          other_user.update!(email_verified_at: Time.current)
          other_token = Doorkeeper::AccessToken.create!(
            application: @application,
            resource_owner_id: other_user.id,
            scopes: "public"
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic.id, text: "unauthorized" },
            headers: { "Authorization" => "Bearer #{other_token.token}" },
            as: :json

          assert_response :forbidden
        end

        # --- Destroy ---

        test "destroy archives topic with topic_id param" do
          reg = register_agent("destroy-test")

          delete "/api/v1/agent/#{reg['agent_id']}",
            params: { topic_id: reg["topic_id"] },
            headers: auth_headers,
            as: :json

          assert_response :no_content

          topic = Topic.find(reg["topic_id"])
          assert topic.archived?
        end

        test "destroy still requires topic_id" do
          # Per-session agents removed the sibling-collision concern, but the
          # endpoint contract still requires an explicit topic_id so the
          # caller declares which session topic is ending.
          reg = register_agent("session-x")

          delete "/api/v1/agent/#{reg['agent_id']}",
            headers: auth_headers,
            as: :json
          assert_response :unprocessable_entity

          assert_not Topic.find(reg["topic_id"]).archived?
        end

        test "destroy rejects non-owned agent" do
          reg = register_agent("other-test")

          other_user = users(:two)
          other_user.update!(email_verified_at: Time.current)
          other_token = Doorkeeper::AccessToken.create!(
            application: @application,
            resource_owner_id: other_user.id,
            scopes: "public"
          )

          delete "/api/v1/agent/#{reg['agent_id']}",
            headers: { "Authorization" => "Bearer #{other_token.token}" },
            as: :json

          assert_response :not_found
        end

        test "destroy returns not_found for non-existent agent" do
          delete "/api/v1/agent/999999",
            headers: auth_headers,
            as: :json
          assert_response :not_found
        end

        test "destroy fails delegated tasks and releases agent slot before archive" do
          reg = register_agent("unregister-delegated-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          task = Collavre::Task.create!(
            name: "Delegated",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(task.id)
          assert_equal 1, tracker.active_jobs

          dequeue_called_with = nil
          stub = ->(t, c = nil) { dequeue_called_with = [ t, c ] }

          Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, stub) do
            delete "/api/v1/agent/#{ai_user.id}",
              params: { topic_id: topic_id },
              headers: auth_headers,
              as: :json
          end
          assert_response :no_content

          assert_equal "cancelled", task.reload.status
          assert_equal 0, Collavre::Orchestration::ResourceTracker.for(ai_user).active_jobs,
            "Expected the delegated task's agent slot to be released on unregister"
          assert_equal [ topic_id, creative.id ], dequeue_called_with
          assert Topic.find(topic_id).archived?
        end

        test "destroy cancels delegated tasks on work topics outside the registration inbox" do
          # Real Claude Channel dispatches happen on work topics (non-inbox);
          # inbox comments are skipped by Comment#dispatch_to_orchestration.
          # If unregister only scanned the inbox topic, work-topic delegated
          # tasks would keep holding the slot/topic queue until stuck recovery.
          reg = register_agent("cross-topic-cancel")
          inbox_topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])

          # A delegated task on a *different* (work) topic — the realistic case.
          work_creative = creatives(:tshirt)
          work_topic = work_creative.topics.create!(name: "Work topic", user: @user)
          work_task = Collavre::Task.create!(
            name: "Delegated on work topic",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: work_topic.id,
            creative_id: work_creative.id
          )

          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(work_task.id)
          assert_equal 1, tracker.active_jobs

          dequeue_calls = []
          stub = ->(t, c = nil) { dequeue_calls << [ t, c ] }

          Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, stub) do
            delete "/api/v1/agent/#{ai_user.id}",
              params: { topic_id: inbox_topic_id },
              headers: auth_headers,
              as: :json
          end
          assert_response :no_content

          assert_equal "cancelled", work_task.reload.status,
            "work-topic delegated task must be cancelled on unregister, not just inbox-topic ones"
          assert_equal 0, Collavre::Orchestration::ResourceTracker.for(ai_user).active_jobs,
            "work-topic task's slot must be released"
          assert_includes dequeue_calls, [ work_topic.id, work_creative.id ],
            "work topic queue must be drained on unregister"
          assert Topic.find(inbox_topic_id).archived?
        end

        test "destroy clears routing_expression to exclude session agent from Matcher" do
          # Per-session ai_users left lying around with routing_expression="true"
          # keep being scanned by Orchestration::Matcher#match_by_expression,
          # creating delegated tasks for a session whose MCP client has exited.
          reg = register_agent("disable-routing-test")
          ai_user = User.find(reg["agent_id"])
          assert_equal "true", ai_user.routing_expression,
            "sanity: register should leave routing_expression='true'"

          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: reg["topic_id"] },
            headers: auth_headers,
            as: :json
          assert_response :no_content

          assert_nil ai_user.reload.routing_expression,
            "unregister must null routing_expression so the matcher skips the session agent"
        end

        test "re-register restores routing_expression cleared by prior unregister" do
          first = register_agent("restore-routing-test")
          agent_id = first["agent_id"]
          delete "/api/v1/agent/#{agent_id}",
            params: { topic_id: first["topic_id"] },
            headers: auth_headers,
            as: :json
          assert_response :no_content
          assert_nil User.find(agent_id).routing_expression

          second = register_agent("restore-routing-test")
          assert_equal agent_id, second["agent_id"],
            "same session_name must reuse the same ai_user row"
          assert_equal "true", User.find(agent_id).routing_expression,
            "re-register must restore routing_expression so the matcher can dispatch again"
        end

        test "destroy ignores topic_id that does not belong to the agent" do
          reg = register_agent("ownership-test")
          agent_id = reg["agent_id"]

          # An unrelated active topic in the same inbox (no primary_agent on it,
          # or a different agent) — destroy must NOT archive it.
          inbox = Creative.inbox_for(@user)
          unrelated = inbox.topics.create!(name: "Unrelated", user: @user)

          delete "/api/v1/agent/#{agent_id}",
            params: { topic_id: unrelated.id },
            headers: auth_headers,
            as: :json
          assert_response :no_content

          assert_not unrelated.reload.archived?,
            "destroy must not archive a topic that is not owned by the :id agent"
        end


        private

        def auth_headers
          { "Authorization" => "Bearer #{@token.token}" }
        end

        def register_agent(name)
          post "/api/v1/agent/register",
            params: { name: name },
            headers: auth_headers,
            as: :json
          assert_response :ok
          JSON.parse(response.body)
        end
      end
    end
  end
end
