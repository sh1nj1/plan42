# frozen_string_literal: true

require "test_helper"

module Collavre
  module Api
    module V1
      module Mobile
        class AgentEventsControllerTest < ActionDispatch::IntegrationTest
          DEVICE = "test-device-1"

          setup do
            @user = users(:one)
            @user.update!(email_verified_at: Time.current, locale: "ko")

            @application = Doorkeeper::Application.create!(
              name: "Mobile Test Client",
              redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
              scopes: "public",
              owner: @user
            )
            @token = Doorkeeper::AccessToken.create!(
              application: @application, resource_owner_id: @user.id, scopes: "public"
            )

            @agent = build_agent
            @creative = Creative.create!(user: @user, description: "OpenClaw PR review work")
            @topic = @creative.topics.create!(name: "OpenClaw PR 검토", user: @user)
          end

          test "agent_events requires authentication" do
            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, as: :json
            assert_response :unauthorized
          end

          test "agent_events surfaces a pending approval with a decision summary" do
            create_permission_comment(request_id: "req-1", tool_name: "Edit", description: "Edit 3 files")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
            events = JSON.parse(response.body)

            assert_equal 1, events.size
            ev = events.first
            assert_equal "approval_requested", ev["type"]
            assert ev["requires_response"]
            assert_includes ev["summary"], "Edit 3 files", "the spoken summary names what is being approved"
          end

          test "event title is the Creative#Topic the message belongs to" do
            create_permission_comment(request_id: "req-title", tool_name: "Edit")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            ev = JSON.parse(response.body).first
            assert_equal "OpenClaw PR review work#OpenClaw PR 검토", ev["title"],
              "the app lists messages titled 크리에이티브#토픽 so the user knows the thread"
          end

          test "event title strips HTML from the creative description (matches web chat snippet)" do
            html_creative = Creative.create!(
              user: @user,
              description: "<p>Voice <strong>Companion</strong> &amp; UI</p>"
            )
            topic = html_creative.topics.create!(name: "UI 개선", user: @user)
            create_permission_comment(request_id: "req-html", tool_name: "Edit", topic: topic)

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            ev = JSON.parse(response.body).find { |e| e["title"]&.end_with?("#UI 개선") }
            assert_equal "Voice Companion & UI#UI 개선", ev["title"],
              "the title is HTML-stripped/unescaped like the web chat header (creative_snippet)"
          end

          test "a still-pending approval keeps surfacing on every poll (server holds no cursor)" do
            create_permission_comment(request_id: "req-once", tool_name: "Edit")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_equal 1, JSON.parse(response.body).size

            # The server keeps no per-client cursor: an undecided approval is emitted
            # again next poll. Re-speaking is suppressed on the client (in-memory
            # "already spoken" set), and a restart correctly re-surfaces it.
            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
            assert_equal 1, JSON.parse(response.body).size,
              "a pending approval stays in the stream until it is decided"
          end

          test "a pending approval stops surfacing once it is decided" do
            comment = create_permission_comment(request_id: "req-keepref", tool_name: "Bash")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_equal 1, JSON.parse(response.body).size

            # Deciding it (clearing action_executed_at) drops it from pending_approvals.
            post "/api/v1/mobile/agent_events/#{comment.id}/respond",
              params: { device_id: DEVICE, response: "approve" }, headers: auth_headers, as: :json
            assert_response :ok
            assert_equal "allow", JSON.parse(comment.reload.action)["decision"]

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_empty JSON.parse(response.body), "a decided approval no longer surfaces"
          end

          test "all undecided approvals surface together, newest and oldest alike" do
            create_permission_comment(request_id: "req-old", tool_name: "Edit")

            travel_to 5.seconds.from_now do
              create_permission_comment(request_id: "req-new", tool_name: "Bash")
              get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            end
            request_ids = JSON.parse(response.body).map do |e|
              Collavre::Comment.find(e["id"]).claude_channel_permission_request_id
            end
            assert_equal %w[req-new req-old], request_ids.sort,
              "no server cursor drops the older approval; both pending prompts surface"
          end

          test "an unknown since param from an older client is harmlessly ignored" do
            create_permission_comment(request_id: "req-back-compat", tool_name: "Edit")

            # Old APKs still send a `since` cursor; the server no longer reads it and
            # must not error or suppress anything.
            get "/api/v1/mobile/agent_events",
              params: { device_id: DEVICE, since: 1.hour.from_now.iso8601(6) },
              headers: auth_headers, as: :json
            assert_response :ok
            assert_equal 1, JSON.parse(response.body).size,
              "a stale since cursor no longer hides a pending approval"
          end

          test "respond approve decides the permission and broadcasts to the suspended session" do
            comment = create_permission_comment(request_id: "req-approve", tool_name: "Bash")

            broadcasts = []
            ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
              post "/api/v1/mobile/agent_events/#{comment.id}/respond",
                params: { device_id: DEVICE, response: "approve" }, headers: auth_headers, as: :json
            end
            assert_response :ok
            body = JSON.parse(response.body)
            assert_equal "approved", body.dig("action", "type")
            assert body["speak"]

            comment.reload
            assert comment.action_executed_at.present?, "decision must be recorded"
            assert_equal "allow", JSON.parse(comment.action)["decision"]
            assert_equal @user.id, comment.action_executed_by_id

            decision = broadcasts.map { |b| b[:data] }.find { |d| d.is_a?(Hash) && d[:type] == "permission_decision" }
            assert_equal "req-approve", decision[:request_id]
            assert_equal "allow", decision[:behavior]
          end

          test "respond deny records a deny decision" do
            comment = create_permission_comment(request_id: "req-deny", tool_name: "Bash")
            post "/api/v1/mobile/agent_events/#{comment.id}/respond",
              params: { device_id: DEVICE, response: "deny" }, headers: auth_headers, as: :json
            assert_response :ok
            assert_equal "deny", JSON.parse(comment.reload.action)["decision"]
          end

          test "respond on an already-decided approval is idempotent" do
            comment = create_permission_comment(request_id: "req-twice", tool_name: "Bash")
            comment.decide_claude_channel_permission!("allow", by: @user)

            post "/api/v1/mobile/agent_events/#{comment.id}/respond",
              params: { device_id: DEVICE, response: "deny" }, headers: auth_headers, as: :json
            assert_response :ok
            assert_equal "already_decided", JSON.parse(response.body).dig("action", "type")
            assert_equal "allow", JSON.parse(comment.reload.action)["decision"], "first decision wins"
          end

          test "a message in the user's Inbox#System surfaces as an event read aloud" do
            origin = @creative.comments.create!(
              content: "주말 여행으로 어디가 좋을까요? 추천해줘", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true
            )
            notice = create_system_inbox_notice(
              quoted: origin,
              content: "AI 님이 \"[테스트](/creatives/6?open_comments=true)\" 에서 당신을 언급했습니다: \"주말 여행으로 어디가 좋을까요?\""
            )

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
            ev = JSON.parse(response.body).find { |e| e["id"] == notice.id }

            assert ev, "Inbox#System alarms must surface as events (the bug: they never did → never read)"
            assert_equal "OpenClaw PR review work#OpenClaw PR 검토", ev["title"],
              "title is the ORIGIN thread (크리에이티브#토픽), not Inbox#System"
            assert_equal @topic.id, ev["topic_id"], "the event points at the origin thread"
            assert ev["requires_response"], "after reading, the app listens for a reply"
            assert_includes ev["summary"], "당신을 언급했습니다", "the full message content is spoken"
            refute_includes ev["summary"], "](", "markdown link syntax is stripped so TTS doesn't read URLs"
          end

          test "responding to an Inbox#System message routes the reply to the origin topic" do
            origin = @creative.comments.create!(
              content: "어느 브랜치에 머지할까요?", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true
            )
            notice = create_system_inbox_notice(quoted: origin, content: "언급: 어느 브랜치에 머지할까요?")

            assert_difference -> { Comment.count }, 1 do
              post "/api/v1/mobile/agent_events/#{notice.id}/respond",
                params: { device_id: DEVICE, response: "메인에 머지해" }, headers: auth_headers, as: :json
            end
            assert_response :ok
            assert_equal "relayed", JSON.parse(response.body).dig("action", "type")

            relayed = Comment.order(:id).last
            assert_equal "메인에 머지해", relayed.content
            assert_equal @user.id, relayed.user_id, "the human authors the reply"
            assert_equal @topic.id, relayed.topic_id, "reply lands on the ORIGIN thread, not the (non-dispatching) System topic"
            assert_equal origin.id, relayed.quoted_comment_id, "reply quotes the origin comment so the agent threads it"
          end

          test "the relayed reply is a question, not a review, so the agent posts a new reply (firing the alarm)" do
            origin = @creative.comments.create!(
              content: "어느 브랜치에 머지할까요?", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true
            )
            notice = create_system_inbox_notice(quoted: origin, content: "언급: 어느 브랜치에 머지할까요?")

            post "/api/v1/mobile/agent_events/#{notice.id}/respond",
              params: { device_id: DEVICE, response: "메인에 머지해" }, headers: auth_headers, as: :json
            assert_response :ok

            relayed = Comment.order(:id).last
            # quoted_comment is set only for threading. Without review_type: :question
            # the reply is a review_message? → the agent UPDATES the quoted comment in
            # place (review flow) instead of posting a new reply, so no new comment is
            # created and the Inbox#System alarm never fires. See Comment#review_message?.
            assert relayed.review_type_question?, "the relay must be a question so the agent threads a NEW reply"
            refute relayed.review_message?, "a review_message? would be overwritten in place, suppressing the alarm"
          end

          test "an approval's Inbox#System FYI is not read a second time (pending_approvals owns it)" do
            perm = create_permission_comment(request_id: "req-dup", tool_name: "Edit", description: "Edit 3 files")
            create_system_inbox_notice(quoted: perm, content: "승인 요청: Edit")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            events = JSON.parse(response.body)

            assert_equal 1, events.size, "the approval surfaces once (actionable), not again as a System FYI duplicate"
            assert_equal "approval_requested", events.first["type"]
          end

          test "an unread Inbox#System message surfaces regardless of the client since cursor" do
            # The bug: the app advances a private created_at `since` cursor at fetch
            # time, so a notice fetched-but-never-spoken (crash/background/queue) is
            # burned past and never re-emitted — it sits unread in the inbox forever.
            # Emission must be driven by the inbox's OWN read-state (CommentReadPointer),
            # not the client cursor: an UNREAD notice surfaces even if `since` is ahead.
            origin = @creative.comments.create!(
              content: "원본 메세지", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true
            )
            notice = create_system_inbox_notice(quoted: origin, content: "언급: 원본 메세지")

            future = (notice.created_at + 1.hour).iso8601(6)
            get "/api/v1/mobile/agent_events",
              params: { device_id: DEVICE, since: future }, headers: auth_headers, as: :json
            assert_response :ok
            ids = JSON.parse(response.body).map { |e| e["id"] }
            assert_includes ids, notice.id,
              "an unread notice must surface even when the client cursor is ahead of it"
          end

          test "reading a notice (POST read) marks it read so it stops surfacing" do
            origin = @creative.comments.create!(
              content: "원본", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true
            )
            notice = create_system_inbox_notice(quoted: origin, content: "언급: 원본")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_includes JSON.parse(response.body).map { |e| e["id"] }, notice.id

            post "/api/v1/mobile/agent_events/#{notice.id}/read",
              params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            refute_includes JSON.parse(response.body).map { |e| e["id"] }, notice.id,
              "once read aloud (marked read) the notice no longer surfaces"

            inbox = Collavre::Creative.inbox_for(@user)
            pointer = Collavre::CommentReadPointer.find_by(user: @user, creative: inbox)
            assert pointer && pointer.last_read_comment_id >= notice.id,
              "marking read advances the inbox read pointer (same state as the badge)"
          end

          test "a newer unread notice still surfaces after an older one is marked read" do
            o1 = @creative.comments.create!(content: "첫째", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true)
            n1 = create_system_inbox_notice(quoted: o1, content: "언급: 첫째")
            o2 = @creative.comments.create!(content: "둘째", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true)
            n2 = create_system_inbox_notice(quoted: o2, content: "언급: 둘째")

            post "/api/v1/mobile/agent_events/#{n1.id}/read",
              params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            ids = JSON.parse(response.body).map { |e| e["id"] }
            refute_includes ids, n1.id, "the read notice is gone"
            assert_includes ids, n2.id, "the newer unread notice still surfaces"
          end

          test "respond to a free-form agent message relays the utterance verbatim" do
            agent_reply = @creative.comments.create!(
              content: "어떤 브랜치에 머지할까요?", user: @agent, topic: @topic,
              skip_default_user: true, skip_dispatch: true
            )

            assert_difference -> { Comment.count }, 1 do
              post "/api/v1/mobile/agent_events/#{agent_reply.id}/respond",
                params: { device_id: DEVICE, response: "메인 브랜치에 머지해" }, headers: auth_headers, as: :json
            end
            assert_response :ok
            assert_equal "relayed", JSON.parse(response.body).dig("action", "type")

            relayed = Comment.order(:id).last
            assert_equal "메인 브랜치에 머지해", relayed.content
            assert_equal @user.id, relayed.user_id, "relay is authored by the human, not the agent"
            assert_equal @topic.id, relayed.topic_id
          end

          test "respond refuses to decide a permission the caller is not the approver for" do
            # Authored by the caller's own agent — so authorized_comment? lets the
            # request through — but the designated approver is someone else. The
            # decision must still be refused (the web path's approval_status gate).
            other = users(:two)
            comment = @creative.comments.create!(
              content: "🔐 Bash permission", user: @agent, topic: @topic, approver: other,
              action: JSON.pretty_generate("action" => "claude_channel_permission",
                                           "request_id" => "req-foreign-approver", "tool_name" => "Bash"),
              skip_default_user: true, skip_dispatch: true
            )

            post "/api/v1/mobile/agent_events/#{comment.id}/respond",
              params: { device_id: DEVICE, response: "approve" }, headers: auth_headers, as: :json

            assert_response :forbidden
            assert_equal "not_authorized", JSON.parse(response.body).dig("action", "type")
            assert_nil JSON.parse(comment.reload.action)["decision"],
              "a permission the caller does not approve must not be decided via the voice path"
          end

          test "respond refuses an event the caller does not own" do
            other = users(:two)
            foreign_agent = User.create!(
              email: "foreign-voice@collavre.local", password: SecureRandom.hex(16),
              name: "Foreign", llm_vendor: "anthropic", llm_model: "claude-code", created_by_id: other.id
            )
            foreign_creative = Creative.create!(user: other, description: "theirs")
            foreign_comment = foreign_creative.comments.create!(
              content: "secret", user: foreign_agent, skip_default_user: true, skip_dispatch: true
            )

            post "/api/v1/mobile/agent_events/#{foreign_comment.id}/respond",
              params: { device_id: DEVICE, response: "approve" }, headers: auth_headers, as: :json
            assert_response :not_found
          end

          private

          def auth_headers
            { "Authorization" => "Bearer #{@token.token}" }
          end

          def build_agent
            User.create!(
              email: "voice-agent-#{SecureRandom.hex(4)}@collavre.local",
              password: SecureRandom.hex(16), name: "Claude Channel (voice)",
              llm_vendor: "anthropic", llm_model: "claude-code", created_by_id: @user.id
            )
          end

          # Mirrors Notifiable#create_inbox_comment: a system-authored (user_id nil)
          # comment in the user's Inbox#System topic that QUOTES the origin comment.
          def create_system_inbox_notice(quoted:, content:)
            inbox = Collavre::Creative.inbox_for(@user)
            Comment.create!(
              creative: inbox, topic: inbox.system_topic, content: content,
              user: nil, skip_default_user: true, quoted_comment: quoted
            )
          end

          def create_permission_comment(request_id:, tool_name:, description: nil, topic: @topic)
            payload = { "action" => "claude_channel_permission", "request_id" => request_id,
                        "tool_name" => tool_name }
            payload["description"] = description if description
            topic.creative.comments.create!(
              content: "🔐 #{tool_name} permission",
              user: @agent, topic: topic, approver: @user,
              action: JSON.pretty_generate(payload),
              skip_default_user: true, skip_dispatch: true
            )
          end
        end
      end
    end
  end
end
