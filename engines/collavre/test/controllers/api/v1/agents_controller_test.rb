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
          email = session_agent_email(slug)
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
          email = session_agent_email(slug)
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

        # --- Agent/Session split (agent_name + session_id) ---

        test "register keys the agent by agent_name and the topic by session_id" do
          post "/api/v1/agent/register",
            params: { agent_name: "claude", session_id: "sess-alpha" },
            headers: auth_headers,
            as: :json
          assert_response :ok
          body = JSON.parse(response.body)

          ai_user = User.find(body["agent_id"])
          assert ai_user.claude_channel_agent?
          # Agent identity derives from agent_name, NOT the session id.
          assert_equal session_agent_email("claude"), ai_user.email
          # The topic carries the session id so re-register can find it.
          assert_equal "sess-alpha", Topic.find(body["topic_id"]).session_id
          assert_equal "sess-alpha", body["session_id"]
        end

        test "register: one agent_name with two session_ids yields one agent and two topics" do
          # The headline multi-session case: without a distinct AGENT_NAME, every
          # Claude Code session for one human collapses onto a single shared
          # ai_user, but each session gets its own Collavre topic.
          assert_difference -> { User.count }, 1 do
            post "/api/v1/agent/register",
              params: { agent_name: "claude", session_id: "sess-1" },
              headers: auth_headers, as: :json
            assert_response :ok
            post "/api/v1/agent/register",
              params: { agent_name: "claude", session_id: "sess-2" },
              headers: auth_headers, as: :json
            assert_response :ok
          end

          agents = User.where(created_by_id: @user.id, llm_model: "claude-code")
          assert_equal 1, agents.count, "both sessions must share one agent"
          assert_equal 2, Topic.where(primary_agent_id: agents.first.id).count,
            "each session must get its own topic under the shared agent"
        end

        test "register: same agent_name and session_id is idempotent (one agent, one topic)" do
          assert_difference -> { User.count }, 1 do
            2.times do
              post "/api/v1/agent/register",
                params: { agent_name: "claude", session_id: "sess-same" },
                headers: auth_headers, as: :json
              assert_response :ok
            end
          end

          agent = User.where(created_by_id: @user.id, llm_model: "claude-code").first
          assert_equal 1, Topic.where(primary_agent_id: agent.id).count,
            "re-registering the same session must not duplicate the topic"
        end

        test "register: distinct agent_name in the same session_id yields distinct agents" do
          # Explicit AGENT_NAME carves out a separate agent even when the session
          # id collides (e.g. two agents launched from the same cwd).
          assert_difference -> { User.count }, 2 do
            post "/api/v1/agent/register",
              params: { agent_name: "claude", session_id: "shared-cwd" },
              headers: auth_headers, as: :json
            assert_response :ok
            a = JSON.parse(response.body)

            post "/api/v1/agent/register",
              params: { agent_name: "ops", session_id: "shared-cwd" },
              headers: auth_headers, as: :json
            assert_response :ok
            b = JSON.parse(response.body)

            assert_not_equal a["agent_id"], b["agent_id"]
            assert_not_equal a["topic_id"], b["topic_id"]
          end
        end

        test "register does not alias distinct agent_names that share a lossy slug" do
          # Codex P2: the readable slug squeezes "qa/bot", "qa bot" and "qa--bot"
          # all to "qa-bot". Keying identity on the slug alone would silently
          # merge these distinct configured agents onto one ai_user (sharing its
          # stream, routing, tasks, shares). A digest of the raw name keeps them
          # distinct while same-name re-register stays idempotent.
          post "/api/v1/agent/register",
            params: { agent_name: "qa/bot", session_id: "sess-1" },
            headers: auth_headers, as: :json
          assert_response :ok
          a = JSON.parse(response.body)

          post "/api/v1/agent/register",
            params: { agent_name: "qa-bot", session_id: "sess-2" },
            headers: auth_headers, as: :json
          assert_response :ok
          b = JSON.parse(response.body)

          assert_not_equal a["agent_id"], b["agent_id"],
            "distinct names that share a slug must not collapse to one agent"
          assert_not_equal User.find(a["agent_id"]).email, User.find(b["agent_id"]).email

          # Same raw name still reuses the same agent (idempotency preserved).
          post "/api/v1/agent/register",
            params: { agent_name: "qa/bot", session_id: "sess-3" },
            headers: auth_headers, as: :json
          assert_response :ok
          again = JSON.parse(response.body)
          assert_equal a["agent_id"], again["agent_id"], "same raw name must reuse its agent"
        end

        test "register uses session_label for the topic name when provided" do
          post "/api/v1/agent/register",
            params: { agent_name: "claude", session_id: "sess-x", session_label: "plan42-worktree87" },
            headers: auth_headers, as: :json
          assert_response :ok
          body = JSON.parse(response.body)
          assert_equal "Claude plan42-worktree87", body["topic_name"]
        end

        test "register disambiguates a colliding topic name across sessions" do
          # The (creative_id, name) unique index means two sessions that would
          # produce the same friendly name must not collide on create.
          post "/api/v1/agent/register",
            params: { agent_name: "claude", session_id: "sess-a", session_label: "src" },
            headers: auth_headers, as: :json
          assert_response :ok
          post "/api/v1/agent/register",
            params: { agent_name: "claude", session_id: "sess-b", session_label: "src" },
            headers: auth_headers, as: :json
          assert_response :ok
          second = JSON.parse(response.body)
          assert_not_equal "Claude src", second["topic_name"],
            "second session with the same label must get a disambiguated topic name"
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

        test "legacy reply (no task_id) is refused when primary_agent is not a Claude Channel agent" do
          # The legacy fallback in resolve_reply_agent must apply the same
          # claude_channel_agent? gate as the task_id path. Otherwise a caller
          # with feedback permission could POST /reply (no task_id) on an
          # ordinary topic whose primary_agent is a normal AI user and save an
          # unlinked comment authored as that AI user.
          normal_agent = User.create!(
            email: "normal-ai@collavre.local",
            password: "password123",
            name: "Normal AI",
            llm_vendor: "google",
            llm_model: "gemini-1.5-flash",
            created_by_id: @user.id
          )
          assert_not normal_agent.claude_channel_agent?

          creative = Creative.create!(user: @user, description: "Ordinary creative")
          topic = creative.topics.create!(name: "Ordinary topic", user: @user)
          topic.set_primary_agent!(normal_agent)

          before = Comment.count
          post "/api/v1/agent/reply",
            params: { topic_id: topic.id, text: "Impersonation attempt" },
            headers: auth_headers,
            as: :json

          assert_response :forbidden
          assert_equal before, Comment.count,
            "no comment may be saved as a non-Claude-Channel primary_agent via the legacy reply fallback"
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

        test "reply broadcasts idle agent_status so the typing indicator clears" do
          reg = register_agent("reply-idle-test")
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

          broadcasts = []
          ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
            post "/api/v1/agent/reply",
              params: { topic_id: topic_id, task_id: task.id, text: "Claude responded" },
              headers: auth_headers,
              as: :json
          end
          assert_response :created

          idle = broadcasts
                 .select { |b| b[:data].is_a?(Hash) && b[:data][:agent_status].present? }
                 .map { |b| b[:data][:agent_status] }
                 .find { |s| s[:status] == "idle" && s[:id] == ai_user.id }
          assert_not_nil idle, "expected an idle agent_status broadcast on reply to clear the typing indicator"
          assert_equal task.id, idle[:task_id]
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

        test "notify with permission_request_id parks the delegated task as awaiting a decision" do
          # When the relayed comment is a native tool-permission prompt, the
          # in-flight dispatch must be parked (pending_tool_call) so the human's
          # subsequent allow/deny is relayed straight to the suspended session
          # by Comment#dispatch_to_orchestration instead of deadlocking behind
          # the delegated topic slot.
          reg = register_agent("notify-perm-park-test")
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
            params: { topic_id: topic_id, text: "🔐 권한 요청: Bash", task_id: task.id, permission_request_id: "req-42" },
            headers: auth_headers,
            as: :json
          assert_response :created

          assert_equal "delegated", task.reload.status,
            "parking the prompt must not complete the in-flight task"
          assert_equal "req-42", task.pending_tool_call&.dig("request_id"),
            "the delegated task must be parked as awaiting a permission decision"
        end

        test "notify with permission_request_id builds a structured approval comment" do
          # The plugin sends only tool_name + arguments; the server renders the
          # (localized) prompt text server-side and attaches the approve/deny
          # action payload + approver so the native approval UI surfaces.
          reg = register_agent("notify-perm-structured-test")
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
            params: {
              topic_id: topic_id,
              task_id: task.id,
              permission_request_id: "req-99",
              tool_name: "Bash",
              arguments: { command: "ls -la" }
            },
            headers: auth_headers,
            as: :json
          assert_response :created

          comment = Comment.find(JSON.parse(response.body)["comment_id"])
          assert comment.claude_channel_permission?, "permission notify must build a structured permission comment"
          assert_equal "req-99", comment.claude_channel_permission_request_id
          assert_equal @user.id, comment.approver_id, "the token holder approves their session's prompts"
          assert_includes comment.content, "Bash"
          assert_includes comment.content, "ls -la"
          refute comment.action_executed_at.present?, "a freshly surfaced prompt is undecided"
        end

        test "notify renders the permission prompt in the token holder's locale" do
          # The prompt text is persisted server-side via I18n at notify time, so
          # it must be rendered in the token holder's locale — the API base
          # controller only authenticates the bearer token and never runs the
          # host app's locale switching, so I18n would otherwise fall back to the
          # process default and a ko approver would receive an English prompt.
          @user.update!(locale: "ko")
          reg = register_agent("notify-perm-locale-test")
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
            params: {
              topic_id: topic_id,
              task_id: task.id,
              permission_request_id: "req-ko",
              tool_name: "Bash",
              arguments: { command: "ls -la" }
            },
            headers: auth_headers,
            as: :json
          assert_response :created

          comment = Comment.find(JSON.parse(response.body)["comment_id"])
          expected = I18n.t("collavre.claude_channel.permission.message",
                            tool_name: "Bash", arguments: "", description: "", locale: :ko).split("\n").first
          assert_includes comment.content, expected.strip,
            "permission prompt must be localized to the token holder's locale (ko)"
          refute_includes comment.content,
            I18n.t("collavre.claude_channel.permission.message",
                   tool_name: "Bash", arguments: "", description: "", locale: :en).split("\n").first.strip,
            "ko approver must not receive the default-locale (en) prompt"
        end

        test "notify surfaces the permission description in the approval prompt" do
          # Claude Code includes a human-readable `description` summary in each
          # permission_request. For tools whose arguments are opaque, omitted, or
          # truncated, that summary is the only thing telling the approver what
          # they are about to allow, so it must survive into the persisted prompt
          # instead of being dropped before the comment is rendered.
          reg = register_agent("notify-perm-description-test")
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
            params: {
              topic_id: topic_id,
              task_id: task.id,
              permission_request_id: "req-desc",
              tool_name: "Bash",
              description: "Delete all build artifacts under tmp/",
              arguments: { command: "rm -rf tmp/build" }
            },
            headers: auth_headers,
            as: :json
          assert_response :created

          comment = Comment.find(JSON.parse(response.body)["comment_id"])
          assert_includes comment.content, "Delete all build artifacts under tmp/",
            "the human-readable permission description must be shown to the approver"
        end

        test "notify escapes a string permission preview so it cannot break the markdown fence" do
          # input_preview arrives as a string for many tools (e.g. a Bash
          # command). It is rendered inside a ```json fence and the comment is
          # later passed through renderCommentMarkdown, so a preview containing a
          # line of ``` would close the fence early and render the remainder as
          # live markdown — letting an attacker-influenced tool input show the
          # approver a misleading prompt instead of the exact arguments. The
          # string must be serialized (JSON) so embedded newlines collapse and no
          # payload line can begin a fence delimiter.
          reg = register_agent("notify-perm-fence-test")
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

          injection = "echo hi\n```\n## Approved by admin\n```json"
          post "/api/v1/agent/notify",
            params: {
              topic_id: topic_id,
              task_id: task.id,
              permission_request_id: "req-fence",
              tool_name: "Bash",
              arguments: injection
            },
            headers: auth_headers,
            as: :json
          assert_response :created

          comment = Comment.find(JSON.parse(response.body)["comment_id"])
          # The template opens with ```json and closes with a bare ``` line, so
          # exactly one standalone ``` line is legitimate. A raw preview would add
          # its own bare ``` line, closing the fence early.
          bare_fence_lines = comment.content.lines.count { |line| line.strip == "```" }
          assert_equal 1, bare_fence_lines,
            "a string preview must not introduce a bare ``` line that escapes the fence"
          refute_match(/^## Approved by admin/, comment.content,
            "injected markdown must not render as a live heading outside the fence")
          assert_includes comment.content, "echo hi",
            "the preview content itself must still be shown to the approver"
        end

        test "notify keeps a multi-line permission description inside its blockquote" do
          # description is the same untrusted, markdown-rendered surface as the
          # arguments preview: it is interpolated into a "> %{text}" blockquote, so
          # a multi-line value could open a heading or fence on a fresh line and
          # break out into live markdown that misleads the approver. It must be
          # flattened so every part stays within the single blockquote line.
          reg = register_agent("notify-perm-desc-injection-test")
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
            params: {
              topic_id: topic_id,
              task_id: task.id,
              permission_request_id: "req-desc-inj",
              tool_name: "Bash",
              description: "Looks safe\n## Approved by admin\n```\nrm -rf /",
              arguments: { command: "ls" }
            },
            headers: auth_headers,
            as: :json
          assert_response :created

          comment = Comment.find(JSON.parse(response.body)["comment_id"])
          refute_match(/^## Approved by admin/, comment.content,
            "a description must not break out of its blockquote into a live heading")
          assert_includes comment.content, "Looks safe",
            "the description text itself must still reach the approver"
        end

        test "reply clears pending_tool_call when completing a parked delegated task" do
          reg = register_agent("reply-clears-pending-test")
          topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])
          creative = Topic.find(topic_id).creative.effective_origin

          task = Collavre::Task.create!(
            name: "In-flight dispatch",
            status: "delegated",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: topic_id,
            creative_id: creative.id,
            pending_tool_call: { "request_id" => "req-9" }
          )

          post "/api/v1/agent/reply",
            params: { topic_id: topic_id, text: "done", task_id: task.id },
            headers: auth_headers,
            as: :json
          assert_response :created

          assert_equal "done", task.reload.status
          assert_nil task.pending_tool_call,
            "completing the task must clear the awaiting-permission marker"
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

        test "destroy drains the topic queue after cancelling pending pre-dispatch work" do
          # Pre-dispatch (queued/pending/running) cancellation must drain the
          # topic queue just like the delegated path does. Otherwise, when a
          # live sibling shares a work topic, cancelling this session's pending
          # task without a dequeue strands the sibling's queued task on that
          # topic until some unrelated completion happens to drain it.
          reg = register_agent("drain-pending-test")
          inbox_topic_id = reg["topic_id"]
          ai_user = User.find(reg["agent_id"])

          work_creative = creatives(:tshirt)
          work_topic = work_creative.topics.create!(name: "Shared work topic drain", user: @user)
          # Only a pending task for this agent — no delegated task — so the
          # delegated path's dequeue never fires. The drain must come from the
          # pre-dispatch cancellation path.
          pending_task = Collavre::Task.create!(
            name: "Pending on shared work topic",
            status: "pending",
            trigger_event_name: "comment_created",
            agent: ai_user,
            topic_id: work_topic.id,
            creative_id: work_creative.id
          )

          dequeue_calls = []
          stub = ->(t, c = nil) { dequeue_calls << [ t, c ] }

          Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, stub) do
            delete "/api/v1/agent/#{ai_user.id}",
              params: { topic_id: inbox_topic_id },
              headers: auth_headers,
              as: :json
          end
          assert_response :no_content

          assert_equal "cancelled", pending_task.reload.status
          assert_includes dequeue_calls, [ work_topic.id, work_creative.id ],
            "work topic queue must be drained after cancelling this session's pending task " \
            "so a sibling's queued task on the shared topic is promoted"
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

        test "destroy leaves shared-agent routing and a live sibling's work intact" do
          # Codex P1: two Claude Code sessions share one default agent. When
          # session A unregisters (DELETE) while session B is still live, A's
          # teardown must NOT clear the shared agent's routing or cancel B's
          # in-flight work — the same multi-session hazard fixed for
          # AgentChannel#unsubscribed, but on the HTTP destroy path.
          post "/api/v1/agent/register",
            params: { agent_name: "shared-sib", session_id: "sess-a" },
            headers: auth_headers, as: :json
          assert_response :ok
          reg_a = JSON.parse(response.body)

          post "/api/v1/agent/register",
            params: { agent_name: "shared-sib", session_id: "sess-b" },
            headers: auth_headers, as: :json
          assert_response :ok
          reg_b = JSON.parse(response.body)
          assert_equal reg_a["agent_id"], reg_b["agent_id"], "sanity: sessions share one agent"

          ai_user = User.find(reg_a["agent_id"])
          # Session B is live: holds a presence row, routing active.
          Collavre::AgentSubscription.create!(agent_id: ai_user.id, token: "sess-b-token")
          ai_user.update_column(:routing_expression, "true")

          # B's in-flight delegated work on B's own topic.
          topic_b = Topic.find(reg_b["topic_id"])
          b_task = Collavre::Task.create!(
            name: "B delegated", status: "delegated", trigger_event_name: "comment_created",
            agent: ai_user, topic_id: topic_b.id, creative_id: topic_b.creative.effective_origin.id
          )
          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(b_task.id)

          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: reg_a["topic_id"] },
            headers: auth_headers, as: :json
          assert_response :no_content

          assert_equal "true", ai_user.reload.routing_expression,
            "routing must stay active while the sibling session is still live"
          assert_equal "delegated", b_task.reload.status,
            "the sibling session's in-flight work must not be cancelled"
          assert_equal 1, Collavre::Orchestration::ResourceTracker.for(ai_user).active_jobs,
            "the sibling's reserved slot must not be released"
          assert Topic.find(reg_a["topic_id"]).archived?,
            "the ending session's own topic is still archived"
          assert_not Topic.find(reg_b["topic_id"]).archived?,
            "the sibling's topic must stay active"
        end

        test "destroy cancels the ending session's own-topic work even when a sibling is live" do
          # The flip side of presence-gating: A's own session topic has delegated
          # work whose client (A) is now gone. That is unambiguously A's (keyed by
          # A's session topic_id), so it must still be cancelled and its slot
          # released — only the agent-wide sweep is withheld while B is live.
          post "/api/v1/agent/register",
            params: { agent_name: "shared-own", session_id: "sess-a" },
            headers: auth_headers, as: :json
          assert_response :ok
          reg_a = JSON.parse(response.body)

          post "/api/v1/agent/register",
            params: { agent_name: "shared-own", session_id: "sess-b" },
            headers: auth_headers, as: :json
          assert_response :ok
          reg_b = JSON.parse(response.body)

          ai_user = User.find(reg_a["agent_id"])
          Collavre::AgentSubscription.create!(agent_id: ai_user.id, token: "sess-b-token")
          ai_user.update_column(:routing_expression, "true")

          topic_a = Topic.find(reg_a["topic_id"])
          a_task = Collavre::Task.create!(
            name: "A delegated", status: "delegated", trigger_event_name: "comment_created",
            agent: ai_user, topic_id: topic_a.id, creative_id: topic_a.creative.effective_origin.id
          )
          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(a_task.id)

          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: reg_a["topic_id"] },
            headers: auth_headers, as: :json
          assert_response :no_content

          assert_equal "cancelled", a_task.reload.status,
            "the ending session's own-topic delegated work must be cancelled"
          assert_equal 0, Collavre::Orchestration::ResourceTracker.for(ai_user).active_jobs,
            "the ending session's slot must be released"
          assert_equal "true", ai_user.reload.routing_expression,
            "routing still stays active for the live sibling"
        end

        test "destroy clears routing when the only session's own presence row is still live" do
          # Codex P2: the plugin closes the WebSocket and IMMEDIATELY sends
          # DELETE, so AgentChannel#unsubscribed (which drops the presence row by
          # the server-minted WS token) may not have run yet. If destroy counted
          # this exiting session's OWN still-live row as a live sibling, it would
          # skip the last-session teardown — routing pinned "true", delegated work
          # left holding its slot — and if the WS close is never processed the row
          # only goes stale, with nothing left to clear routing. destroy must drop
          # the exiting session's own row (keyed by its session_id, derived from
          # the required topic_id) BEFORE deciding a sibling is live.
          post "/api/v1/agent/register",
            params: { agent_name: "solo-race", session_id: "sess-solo" },
            headers: auth_headers, as: :json
          assert_response :ok
          reg = JSON.parse(response.body)

          ai_user = User.find(reg["agent_id"])
          # The exiting session's own presence row, stamped with its session_id,
          # is still live (unsubscribed hasn't fired).
          Collavre::AgentSubscription.create!(
            agent_id: ai_user.id, token: "solo-token", session_id: "sess-solo"
          )
          ai_user.update_column(:routing_expression, "true")

          topic = Topic.find(reg["topic_id"])
          task = Collavre::Task.create!(
            name: "solo delegated", status: "delegated", trigger_event_name: "comment_created",
            agent: ai_user, topic_id: topic.id, creative_id: topic.creative.effective_origin.id
          )
          tracker = Collavre::Orchestration::ResourceTracker.for(ai_user)
          tracker.reset!
          tracker.reserve!(task.id)

          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: reg["topic_id"] },
            headers: auth_headers, as: :json
          assert_response :no_content

          assert_nil ai_user.reload.routing_expression,
            "the last session leaving must clear routing even if its own WS row is still live"
          assert_equal "cancelled", task.reload.status,
            "the last session's delegated work must be cancelled, not stranded"
          assert_equal 0, Collavre::Orchestration::ResourceTracker.for(ai_user).active_jobs,
            "the last session's reserved slot must be released"
          assert_equal 0, Collavre::AgentSubscription.where(agent_id: ai_user.id).count,
            "the exiting session's own presence row must be removed by destroy"
        end

        test "destroy drops the exiting session's row via session_id param when topic_id does not resolve" do
          # Review gap: the exiting session is identified by
          #   exiting_session_id = params[:session_id].presence || topic&.session_id
          # If the plugin only sent topic_id and that topic no longer resolves
          # (stale/archived id, or it does not belong to this agent), topic is
          # nil, the fallback yields nil, the own row is NOT dropped, and the
          # last session's own still-live row masquerades as a live sibling —
          # pinning routing_expression "true" on a now-clientless agent until the
          # lease reap. The plugin now always sends its stable session_id, so
          # destroy can identify and drop the exiting row regardless of topic
          # resolution. Lock that contract.
          post "/api/v1/agent/register",
            params: { agent_name: "stale-topic", session_id: "sess-stale" },
            headers: auth_headers, as: :json
          assert_response :ok
          reg = JSON.parse(response.body)

          ai_user = User.find(reg["agent_id"])
          Collavre::AgentSubscription.create!(
            agent_id: ai_user.id, token: "stale-token", session_id: "sess-stale"
          )
          ai_user.update_column(:routing_expression, "true")

          # A non-resolving topic_id (never belonged to this agent), but the
          # stable session_id is supplied — destroy must still tear down.
          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: 999_999, session_id: "sess-stale" },
            headers: auth_headers, as: :json
          assert_response :no_content

          assert_nil ai_user.reload.routing_expression,
            "session_id param must let destroy clear routing even when topic_id does not resolve"
          assert_equal 0, Collavre::AgentSubscription.where(agent_id: ai_user.id).count,
            "the exiting session's own presence row must be removed via session_id"
        end

        test "destroy keeps a live sibling's routing intact and only removes the exiting session's row" do
          # The exiting session's own row must be dropped, but a DISTINCT live
          # sibling's row (different session_id) must survive so routing stays on.
          post "/api/v1/agent/register",
            params: { agent_name: "sib-row", session_id: "sess-a" },
            headers: auth_headers, as: :json
          assert_response :ok
          reg_a = JSON.parse(response.body)

          ai_user = User.find(reg_a["agent_id"])
          # Both sessions hold their own (live) presence rows.
          Collavre::AgentSubscription.create!(
            agent_id: ai_user.id, token: "a-token", session_id: "sess-a"
          )
          Collavre::AgentSubscription.create!(
            agent_id: ai_user.id, token: "b-token", session_id: "sess-b"
          )
          ai_user.update_column(:routing_expression, "true")

          delete "/api/v1/agent/#{ai_user.id}",
            params: { topic_id: reg_a["topic_id"] },
            headers: auth_headers, as: :json
          assert_response :no_content

          assert_equal "true", ai_user.reload.routing_expression,
            "routing must stay active for the still-live sibling session"
          refute Collavre::AgentSubscription.where(agent_id: ai_user.id, session_id: "sess-a").exists?,
            "the exiting session's own presence row must be removed"
          assert Collavre::AgentSubscription.where(agent_id: ai_user.id, session_id: "sess-b").exists?,
            "the live sibling's presence row must survive"
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


        test "register is idempotent when a concurrent session wins the users.email race" do
          # Codex P2: two sessions for the same (user, agent_name) registering at
          # once both pass find_by(email:) before either insert commits; the loser
          # would hit the users.email unique index and 500, aborting one plugin.
          # Simulate the winner committing the row mid-call, then our insert losing.
          original_create = User.method(:create!)
          raised = false
          stub = lambda do |attrs|
            if attrs[:email].to_s.include?("claude-channel-") && !raised
              raised = true
              winner = original_create.call(attrs) # concurrent winner commits
              raise ActiveRecord::RecordNotUnique, "duplicate key (users.email) #{winner.email}"
            end
            original_create.call(attrs)
          end

          User.stub(:create!, stub) do
            post "/api/v1/agent/register",
              params: { agent_name: "claude", session_id: "sess-race" },
              headers: auth_headers,
              as: :json
          end

          assert_response :ok, "the race loser must reuse the winner's row, not 500"
          body = JSON.parse(response.body)
          email = session_agent_email("claude")
          assert_equal email, User.find(body["agent_id"]).email
          assert_equal 1, User.where(email: email).count, "no duplicate agent row"
        end

        test "register does not duplicate the inbox feedback share on re-register" do
          # Codex P2: the inbox CreativeShare create must be atomic
          # (create_or_find_by!) so concurrent siblings can't RecordNotUnique on
          # the [creative_id, user_id] unique index. Guard the de-dup invariant.
          first = register_agent("share-dedup")
          inbox = Creative.inbox_for(@user)

          assert_no_difference -> { CreativeShare.where(creative: inbox).count } do
            register_agent("share-dedup")
          end
          assert_equal 1,
            CreativeShare.where(creative: inbox, user_id: first["agent_id"]).count
        end

        private

        def auth_headers
          { "Authorization" => "Bearer #{@token.token}" }
        end

        # Mirrors AgentsController#session_agent_email: the deterministic agent
        # identity key. The digest of the normalized raw name disambiguates
        # distinct configured names that share a lossy slug.
        def session_agent_email(name)
          normalized = name.to_s.strip.downcase
          slug = normalized.gsub(/[^a-z0-9-]+/, "-").squeeze("-").gsub(/\A-|-\z/, "")
          slug = "session" if slug.blank?
          digest = Digest::SHA256.hexdigest(normalized)[0, 10]
          "claude-channel-#{@user.id}-#{slug}-#{digest}@agent.collavre.local"
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
