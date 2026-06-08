# frozen_string_literal: true

require "test_helper"

module Collavre
  module Api
    module V1
      class AgentsControllerTest < ActionDispatch::IntegrationTest
        include ActiveJob::TestHelper

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
          # Routing is deferred to AgentChannel#subscribe_to_agent_stream so
          # the agent only becomes matchable once a WebSocket subscriber
          # actually exists. Otherwise comments matched between this register
          # call returning and the client's subsequent cable subscribe would
          # dispatch into an empty stream — stuck delegated work.
          assert_nil ai_user.routing_expression,
            "register must NOT activate routing_expression — defer to subscribe"
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

        # --- Notify (out-of-band informational comment, no task completion) ---

        test "notify posts an informational comment as the agent" do
          reg = register_agent("notify-test")
          topic_id = reg["topic_id"]

          post "/api/v1/agent/notify",
            params: { topic_id: topic_id, text: "🔐 권한 요청: Bash" },
            headers: auth_headers,
            as: :json

          assert_response :created
          body = JSON.parse(response.body)
          comment = Comment.find(body["comment_id"])
          assert_equal "🔐 권한 요청: Bash", comment.content
          assert_equal topic_id, comment.topic_id
          assert_equal reg["agent_id"], comment.user_id
        end

        test "notify does NOT complete a delegated task (unlike reply)" do
          # The permission prompt is posted mid-turn while the original task is
          # still delegated. notify must leave that task untouched — otherwise
          # surfacing a prompt would prematurely mark the in-flight task done.
          reg = register_agent("notify-no-complete-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          creative = Topic.find(topic_id).creative.effective_origin

          task = Collavre::Task.create!(
            name: "In-flight dispatch",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          post "/api/v1/agent/notify",
            params: { topic_id: topic_id, text: "awaiting approval" },
            headers: auth_headers,
            as: :json

          assert_response :created
          assert_equal "delegated", task.reload.status,
            "notify must not complete the in-flight delegated task"
          assert_nil Comment.find(JSON.parse(response.body)["comment_id"]).task_id
        end

        test "notify requires authentication" do
          reg = register_agent("notify-auth-test")
          post "/api/v1/agent/notify",
            params: { topic_id: reg["topic_id"], text: "hi" },
            as: :json
          assert_response :unauthorized
        end

        test "notify rejects a topic not owned by the caller's agent" do
          reg = register_agent("notify-owner-test")
          # A topic with no Claude Channel primary agent for this caller.
          other_topic = Topic.create!(
            name: "Foreign topic",
            creative: Creative.inbox_for(@user),
            user: @user
          )

          post "/api/v1/agent/notify",
            params: { topic_id: other_topic.id, text: "hi" },
            headers: auth_headers,
            as: :json
          assert_response :forbidden
        end

        test "notify with task_id authorizes Claude Channel agent on work topic where primary_agent diverges" do
          # A native permission prompt can be raised during a dispatch that
          # selected this session via routing_expression on a *work* topic
          # whose primary_agent is unset or a different agent. The topic-
          # primary_agent gate would 403 and the prompt would never surface in
          # Collavre. The echoed task_id must authorize the dispatched session
          # agent directly — mirroring /reply.
          reg = register_agent("notify-diverge-test")
          ai_user = User.find(reg["agent_id"])

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

          post "/api/v1/agent/notify",
            params: { topic_id: topic.id, text: "🔐 권한 요청: Bash", task_id: task.id },
            headers: auth_headers,
            as: :json
          assert_response :created

          comment = Comment.find(JSON.parse(response.body)["comment_id"])
          assert_equal ai_user.id, comment.user_id,
            "permission prompt must be attributed to the dispatched Claude Channel agent, not topic.primary_agent"
          # notify still must NOT complete the in-flight task even when given a
          # task_id — it uses task_id only to authorize the poster.
          assert_equal "delegated", task.reload.status,
            "notify must not complete the delegated task it authorizes against"
          assert_nil comment.task_id
        end

        test "notify with task_id refuses when task agent is not owned by current_user" do
          # task_id must not become a back-door to post as someone else's agent.
          reg = register_agent("notify-foreign-owner-test")
          topic = Topic.find(reg["topic_id"])
          creative = topic.creative.effective_origin

          foreign_agent = User.create!(
            email: "foreign-notify-claude@agent.collavre.local",
            name: "Foreign Claude",
            password: SecureRandom.hex(32),
            llm_vendor: "anthropic",
            llm_model: "claude-code",
            created_by_id: users(:two).id
          )
          foreign_task = Collavre::Task.create!(
            name: "Foreign delegated task",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: foreign_agent,
            topic_id: topic.id,
            creative_id: creative.id
          )
          comments_before = creative.comments.count

          post "/api/v1/agent/notify",
            params: { topic_id: topic.id, text: "should not post", task_id: foreign_task.id },
            headers: auth_headers,
            as: :json

          assert_response :forbidden
          assert_equal comments_before, creative.comments.count,
            "no comment should be posted when task_id resolves to a foreign agent"
        end

        test "concurrent replies for same task_id only one wins; loser gets 409 without duplicate comment" do
          # Race: two /reply requests for the same task_id can both pass
          # resolve_reply_agent (read-only scope check). Without an atomic
          # WHERE status='delegated' transition, both would save separate
          # comments and both would run complete_delegated_task — producing
          # duplicate linked replies for one dispatch. Atomic claim ensures
          # exactly one /reply wins.
          reg = register_agent("concurrent-reply-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          task = Collavre::Task.create!(
            name: "Race target",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          comments_before = creative.comments.count

          # First reply: wins the atomic claim, transitions task → done.
          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "First reply", task_id: task.id },
            headers: auth_headers,
            as: :json
          assert_response :created
          first_comment_id = JSON.parse(response.body)["comment_id"]
          assert_equal "done", task.reload.status

          # Second reply (same task_id) arrives after the first has completed.
          # The task is no longer in delegated state — resolve_reply_agent
          # cannot find it, returns nil, and reply renders 403. Either way,
          # no duplicate comment is created.
          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "Duplicate reply", task_id: task.id },
            headers: auth_headers,
            as: :json
          # The post-completion lookup falls through resolve_reply_agent (which
          # scopes to status: "delegated") → 403. Either way, the second
          # request must not produce a 2xx.
          refute_includes 200..299, response.status,
            "second reply for an already-completed task must not return 2xx"

          assert_equal comments_before + 1, creative.comments.count,
            "exactly one comment should be linked to one delegated dispatch"
          assert_equal first_comment_id, Comment.where(task_id: task.id).pluck(:id).first,
            "only the winning reply's comment should be linked to the task"
          assert_equal 1, Comment.where(task_id: task.id).count,
            "no duplicate linked replies for one dispatch"
        end

        test "reply atomically claims delegated task — concurrent claim against the same task_id returns 409" do
          # Direct unit-style test of the claim_delegated_task race. Simulate
          # a concurrent winner by flipping the task to "done" BETWEEN
          # resolve_reply_agent and claim_delegated_task — i.e. emulating the
          # window where two Rails workers have both passed the scope check.
          # The atomic WHERE status='delegated' UPDATE must return 0 rows
          # for the loser, producing 409 (not a saved comment).
          reg = register_agent("atomic-claim-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          topic = Topic.find(topic_id)
          creative = topic.creative.effective_origin

          task = Collavre::Task.create!(
            name: "Atomic race target",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id
          )

          comments_before = creative.comments.count

          # Patch claim_delegated_task to simulate a concurrent winner flipping
          # the task to "done" after resolve_reply_agent saw it as "delegated"
          # but before the atomic UPDATE runs.
          original = Collavre::Api::V1::AgentsController.instance_method(:claim_delegated_task)
          Collavre::Api::V1::AgentsController.define_method(:claim_delegated_task) do |agent, topic_arg, requested_task_id|
            # Race in: another worker completes the task before our atomic UPDATE.
            Collavre::Task.where(id: requested_task_id).update_all(status: "done")
            original.bind_call(self, agent, topic_arg, requested_task_id)
          end

          begin
            post "/api/v1/agent/reply",
              params: { topic_id: topic_id, text: "Loser reply", task_id: task.id },
              headers: auth_headers,
              as: :json
          ensure
            Collavre::Api::V1::AgentsController.define_method(:claim_delegated_task, original)
          end

          assert_response :conflict
          assert_equal comments_before, creative.comments.count,
            "loser of the atomic claim must not save a comment"
        end

        test "Claude Channel reply enqueues TriggerLoopCheckJob only AFTER the reply comment is saved" do
          # Regression for Codex P2: claim_delegated_task previously used
          # update! which fires after_update_commit synchronously — but the
          # reply comment hasn't been saved yet at claim time. With a fast
          # worker (cooldown_seconds: 0), TriggerLoopCheckJob could run
          # before comment.save committed, fail to find an agent comment,
          # and leave the drop-trigger loop stuck at state="running" even
          # though the reply is saved a moment later. The fix moves the
          # callback replay into finalize_claimed_task (post-save) via
          # Task#fire_completion_callbacks_after_external_claim.
          reg = register_agent("trigger-loop-timing-test")
          ai_user = User.find(reg["agent_id"])

          parent = Collavre::Creative.create!(
            user: @user,
            description: "Trigger container",
            data: { "trigger" => { "on_child_enter" => true } }
          )
          child = Collavre::Creative.create!(user: @user, description: "Loop child")
          Collavre::Creative.where(id: child.id).update_all(parent_id: parent.id)
          child.reload

          loop_topic = child.topics.create!(name: "Loop topic timing", user: @user)
          loop_topic.set_primary_agent!(ai_user)

          child.update!(data: {
            "trigger" => {
              "loop" => {
                "state" => "running",
                "cooldown_seconds" => 0,
                "trigger_topic_id" => loop_topic.id
              }
            }
          })

          task = Collavre::Task.create!(
            name: "Loop response",
            status: "delegated",
            trigger_event_name: "comment_created",
            trigger_event_payload: { "comment" => { "id" => 999 } },
            agent: ai_user,
            topic_id: loop_topic.id,
            creative_id: child.id
          )

          # Capture: at the moment TriggerLoopCheckJob is enqueued, does the
          # task already have a linked reply_comment? If the enqueue happened
          # during claim_delegated_task (pre-save), reply_comment would still
          # be nil. If the enqueue happened in finalize_claimed_task
          # (post-save), reply_comment is present and the job will succeed.
          reply_comment_present_at_enqueue = nil
          enqueue_called = false
          stub_perform_later = lambda do |task_id|
            enqueue_called = true
            reply_comment_present_at_enqueue = Collavre::Task.find(task_id).reply_comment.present?
            nil
          end

          Collavre::TriggerLoopCheckJob.stub :perform_later, stub_perform_later do
            post "/api/v1/agent/reply",
              params: { topic_id: loop_topic.id, text: "Loop continuation", task_id: task.id },
              headers: auth_headers,
              as: :json
            assert_response :created
          end

          assert enqueue_called, "TriggerLoopCheckJob.perform_later must be invoked"
          assert reply_comment_present_at_enqueue,
            "reply_comment must be linked to the task BEFORE TriggerLoopCheckJob is enqueued so the job can find it"
          assert_equal "done", task.reload.status
        end

        test "Claude Channel reply enqueues TriggerLoopCheckJob for drop-trigger loops" do
          # claim_delegated_task must use update! (not update_all) so that
          # Task's after_update_commit :check_trigger_loop_completion fires
          # on the delegated → done transition. Otherwise drop-trigger loops
          # whose continue step is delegated to a Claude Channel agent stay
          # stuck at state="running" because TriggerLoopCheckJob never
          # enqueues — normal agent completions go through update! so they
          # advance the loop; Claude replies must match that contract.
          reg = register_agent("trigger-loop-callback-test")
          ai_user = User.find(reg["agent_id"])

          # Drop-trigger setup: parent enables on_child_enter, child has
          # the running loop config. Mirrors trigger_loop_candidate? gates.
          parent = Collavre::Creative.create!(
            user: @user,
            description: "Trigger container",
            data: { "trigger" => { "on_child_enter" => true } }
          )
          child = Collavre::Creative.create!(
            user: @user,
            description: "Loop child"
          )
          Collavre::Creative.where(id: child.id).update_all(parent_id: parent.id)
          child.reload

          loop_topic = child.topics.create!(name: "Loop topic", user: @user)
          loop_topic.set_primary_agent!(ai_user)

          child.update!(data: {
            "trigger" => {
              "loop" => {
                "state" => "running",
                "cooldown_seconds" => 0,
                "trigger_topic_id" => loop_topic.id
              }
            }
          })

          task = Collavre::Task.create!(
            name: "Loop response",
            status: "delegated",
            trigger_event_name: "comment_created",
            trigger_event_payload: { "comment" => { "id" => 999 } },
            agent: ai_user,
            topic_id: loop_topic.id,
            creative_id: child.id
          )

          prev_adapter = ActiveJob::Base.queue_adapter
          ActiveJob::Base.queue_adapter = :test
          begin
            assert_enqueued_with(job: Collavre::TriggerLoopCheckJob, args: [ task.id ]) do
              post "/api/v1/agent/reply",
                params: { topic_id: loop_topic.id, text: "Loop continuation", task_id: task.id },
                headers: auth_headers,
                as: :json
              assert_response :created
            end
          ensure
            ActiveJob::Base.queue_adapter = prev_adapter
          end

          assert_equal "done", task.reload.status
        end

        test "reply with unresolved task_id refuses instead of falling back to primary_agent" do
          # A present-but-unresolved task_id means the client believes it is
          # answering a specific dispatch that no longer exists (cancelled,
          # timed out, stale, or wrong topic). Falling through to
          # topic.primary_agent would save the reply against a different task
          # — or no task at all — while leaving the real intended task
          # cancelled/failed. Must return 403 instead.
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

          comments_before = creative.comments.count

          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "Stale id", task_id: 99_999_999 },
            headers: auth_headers,
            as: :json
          assert_response :forbidden

          assert_equal "delegated", delegated.reload.status,
            "real delegated task must not be completed by a foreign task_id"
          assert_equal comments_before, creative.comments.count,
            "no comment should be saved when task_id is unresolved"
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

          comments_before = creative.comments.count

          post "/api/v1/agent/reply",
            params: { topic_id: topic.id, text: "should not bind", task_id: foreign_task.id },
            headers: auth_headers,
            as: :json

          # A present-but-unresolved-for-this-user task_id is a mistargeted
          # reply. The new contract refuses instead of silently rebinding to
          # this token holder's primary_agent.
          assert_response :forbidden
          assert_equal "delegated", foreign_task.reload.status,
            "foreign agent's delegated task must not be completed by this token holder"
          assert_equal comments_before, creative.comments.count,
            "no comment should be saved when task_id resolves to a foreign agent"
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

        test "destroy cancels queued and pending tasks so dequeue does not activate clientless work" do
          # Topic queue (Task.queued_for_topic) is per-topic, not per-agent.
          # Without cancelling this agent's queued/pending tasks first,
          # dequeue_next_for_topic (called for every cancelled delegated task)
          # would flip a queued task for this clientless agent to pending and
          # enqueue AiAgentJob, which broadcasts to an agent stream with no
          # subscriber and leaves the task stuck in delegated until stuck recovery.
          reg = register_agent("cancel-queued-test")
          inbox_topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])

          work_creative = creatives(:tshirt)
          work_topic = work_creative.topics.create!(name: "Work topic queue", user: @user)

          delegated_task = Collavre::Task.create!(
            name: "Delegated",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: work_topic.id,
            creative_id: work_creative.id
          )
          queued_task = Collavre::Task.create!(
            name: "Queued behind delegated",
            status: "queued",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: work_topic.id,
            creative_id: work_creative.id
          )
          pending_task = Collavre::Task.create!(
            name: "Pending mid-dispatch",
            status: "pending",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: work_topic.id,
            creative_id: work_creative.id
          )

          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(delegated_task.id)

          # Spy: dequeue must NOT pick our agent's queued/pending tasks because
          # we cancelled them first. We don't care how many times it's called,
          # only that no AiAgentJob fires for our tasks.
          ai_jobs = []
          job_stub = ->(arg) { ai_jobs << arg }

          Collavre::AiAgentJob.stub(:perform_later, job_stub) do
            delete "/api/v1/agent/#{ai_user.id}",
              params: { topic_id: inbox_topic_id },
              headers: auth_headers,
              as: :json
          end
          assert_response :no_content

          assert_equal "cancelled", queued_task.reload.status,
            "queued task for clientless agent must be cancelled, not left for dequeue to activate"
          assert_equal "cancelled", pending_task.reload.status,
            "pending task for clientless agent must be cancelled before draining"
          assert_equal "cancelled", delegated_task.reload.status
          assert_empty ai_jobs.select { |a| a.respond_to?(:agent_id) && a.agent_id == ai_user.id },
            "no AiAgentJob may be enqueued for this clientless agent during drain"
        end

        test "destroy cancels running tasks and releases reserved slot before delegated transition" do
          # AiAgentJob#perform reserves a slot under task.id and then flips
          # the task from running → delegated. If destroy lands in that
          # window, neither the queued/pending sweep nor the delegated sweep
          # would catch it, the eventual delegated transition (without the
          # reload guard) would overwrite cancelled with delegated, and the
          # slot would stay held until stuck recovery.
          reg = register_agent("cancel-running-test")
          inbox_topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])

          work_creative = creatives(:tshirt)
          work_topic = work_creative.topics.create!(name: "Work topic running", user: @user)

          running_task = Collavre::Task.create!(
            name: "Running pre-delegation",
            status: "running",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: work_topic.id,
            creative_id: work_creative.id
          )

          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(running_task.id)
          assert_equal 1, tracker.active_jobs,
            "sanity: AiAgentJob would have reserved a slot under task.id by now"

          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: inbox_topic_id },
            headers: auth_headers,
            as: :json
          assert_response :no_content

          assert_equal "cancelled", running_task.reload.status,
            "running task must be cancelled so AiAgentJob's reload guard exits before broadcast"
          assert_equal 0, tracker.active_jobs,
            "agent slot must be released so concurrency capacity reflects reality"
        end

        test "destroy clears routing_expression to exclude session agent from Matcher" do
          # Per-session ai_users left lying around with routing_expression="true"
          # keep being scanned by Orchestration::Matcher#match_by_expression,
          # creating delegated tasks for a session whose MCP client has exited.
          reg = register_agent("disable-routing-test")
          ai_user = User.find(reg["agent_id"])
          # Register no longer activates routing — AgentChannel does on subscribe.
          # Simulate a subscribed session by flipping routing_expression manually
          # so destroy has something to clear.
          ai_user.update_column(:routing_expression, "true")

          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: reg["topic_id"] },
            headers: auth_headers,
            as: :json
          assert_response :no_content

          assert_nil ai_user.reload.routing_expression,
            "unregister must null routing_expression so the matcher skips the session agent"
        end

        test "re-register reuses agent but leaves routing_expression nil until subscribe" do
          # After the activation-on-subscribe move, re-register must NOT
          # auto-restore routing_expression: doing so would reopen the race
          # where matched comments broadcast into an empty stream during the
          # window between register returning and the new cable subscribe.
          first = register_agent("restore-routing-test")
          agent_id = first["agent_id"]
          # Simulate live session having activated routing on subscribe.
          User.find(agent_id).update_column(:routing_expression, "true")

          delete "/api/v1/agent/#{agent_id}",
            params: { topic_id: first["topic_id"] },
            headers: auth_headers,
            as: :json
          assert_response :no_content
          assert_nil User.find(agent_id).routing_expression

          second = register_agent("restore-routing-test")
          assert_equal agent_id, second["agent_id"],
            "same session_name must reuse the same ai_user row"
          assert_nil User.find(agent_id).routing_expression,
            "re-register must NOT restore routing_expression — wait for subscribe"
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
