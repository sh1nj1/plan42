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
          assert_equal "Claude Channel", body["agent_name"]
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

        test "register reuses same agent across sessions with different topics" do
          post "/api/v1/agent/register",
            params: { name: "session-1" },
            headers: auth_headers,
            as: :json
          assert_response :ok
          first = JSON.parse(response.body)

          assert_no_difference -> { User.count } do
            post "/api/v1/agent/register",
              params: { name: "session-2" },
              headers: auth_headers,
              as: :json
          end

          assert_response :ok
          second = JSON.parse(response.body)

          assert_equal first["agent_id"], second["agent_id"]
          assert_not_equal first["topic_id"], second["topic_id"]
          assert_equal "Claude session-1", first["topic_name"]
          assert_equal "Claude session-2", second["topic_name"]
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

        test "destroy requires topic_id to avoid archiving a sibling session" do
          # Two concurrent sessions for the same user reuse the same ai_user as
          # primary_agent on both topics. Without topic_id, destroy can't tell
          # which session is ending; it must refuse rather than guess.
          first = register_agent("session-x")
          second = register_agent("session-y")
          assert_equal first["agent_id"], second["agent_id"]

          delete "/api/v1/agent/#{first['agent_id']}",
            headers: auth_headers,
            as: :json
          assert_response :unprocessable_entity

          assert_not Topic.find(first["topic_id"]).archived?
          assert_not Topic.find(second["topic_id"]).archived?
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
