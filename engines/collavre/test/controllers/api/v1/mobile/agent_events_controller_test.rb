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

          test "agent_events surfaces a pending approval with a spoken ref and a decision summary" do
            create_permission_comment(request_id: "req-1", tool_name: "Edit", description: "Edit 3 files")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
            events = JSON.parse(response.body)

            assert_equal 1, events.size
            ev = events.first
            assert_equal "approval_requested", ev["type"]
            assert_equal 1, ev["ref"], "first surfaced item is task 1"
            assert ev["requires_response"]
            assert_includes ev["summary"], "작업 1"
            assert_includes ev["summary"], "Edit 3 files"
          end

          test "the same approval keeps its number across polling cycles" do
            create_permission_comment(request_id: "req-stable", tool_name: "Bash")

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            first = JSON.parse(response.body).first["ref"]

            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            second = JSON.parse(response.body).first["ref"]

            assert_equal first, second, "the ref number must be pinned to the same approval"
          end

          test "respond approve decides the permission and broadcasts to the suspended session" do
            comment = create_permission_comment(request_id: "req-approve", tool_name: "Bash")
            # assign its ref
            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json

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

          def create_permission_comment(request_id:, tool_name:, description: nil)
            payload = { "action" => "claude_channel_permission", "request_id" => request_id,
                        "tool_name" => tool_name }
            payload["description"] = description if description
            @creative.comments.create!(
              content: "🔐 #{tool_name} permission",
              user: @agent, topic: @topic, approver: @user,
              action: JSON.pretty_generate(payload),
              skip_default_user: true, skip_dispatch: true
            )
          end
        end
      end
    end
  end
end
