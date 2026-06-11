# frozen_string_literal: true

require "test_helper"

module Collavre
  module Api
    module V1
      module Mobile
        class VoiceCommandsControllerTest < ActionDispatch::IntegrationTest
          DEVICE = "test-device-vc"

          setup do
            @user = users(:one)
            @user.update!(email_verified_at: Time.current, locale: "ko")
            @application = Doorkeeper::Application.create!(
              name: "VC Test", redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
              scopes: "public", owner: @user
            )
            @token = Doorkeeper::AccessToken.create!(
              application: @application, resource_owner_id: @user.id, scopes: "public"
            )
            @agent = User.create!(
              email: "vc-agent-#{SecureRandom.hex(4)}@collavre.local", password: SecureRandom.hex(16),
              name: "Claude Channel", llm_vendor: "anthropic", llm_model: "claude-code", created_by_id: @user.id
            )
            @creative = Creative.create!(user: @user, description: "OpenClaw PR")
            @topic = @creative.topics.create!(name: "OpenClaw PR 검토", user: @user)
          end

          test "voice_commands requires authentication" do
            post "/api/v1/mobile/voice_commands", params: { text: "상태", device_id: DEVICE }, as: :json
            assert_response :unauthorized
          end

          test "spoken '1번 승인' decides the approval the grammar fast-path resolves" do
            comment = permission_comment("req-vc-1", "Bash")
            assign_ref!

            post "/api/v1/mobile/voice_commands",
              params: { text: "1번 승인", device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
            assert_equal "approved", JSON.parse(response.body).dig("action", "type")
            assert_equal "allow", JSON.parse(comment.reload.action)["decision"]
          end

          test "spoken '1번 거절' denies via the grammar fast-path" do
            comment = permission_comment("req-vc-2", "Bash")
            assign_ref!

            post "/api/v1/mobile/voice_commands",
              params: { text: "1번 거절해", device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
            assert_equal "deny", JSON.parse(comment.reload.action)["decision"]
          end

          test "status reports active references" do
            permission_comment("req-vc-3", "Bash")
            assign_ref!

            post "/api/v1/mobile/voice_commands",
              params: { text: "상태 알려줘", device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
            body = JSON.parse(response.body)
            assert_equal "status", body.dig("action", "type")
            assert_equal 1, body.dig("action", "count")
            assert_includes body["reply"], "작업 1"
          end

          test "a free-form task command posts to the inbox and reports sent" do
            assert_difference -> { Comment.count }, 1 do
              post "/api/v1/mobile/voice_commands",
                params: { text: "오늘 할 일 정리해", device_id: DEVICE }, headers: auth_headers, as: :json
            end
            assert_response :ok
            assert_equal "message_sent", JSON.parse(response.body).dig("action", "type")
          end

          test "a pre-structured on-device intent bypasses the text resolver" do
            comment = permission_comment("req-vc-4", "Bash")
            assign_ref!

            post "/api/v1/mobile/voice_commands",
              params: { intent: { type: "approve", ref: 1, behavior: "allow" }, device_id: DEVICE },
              headers: auth_headers, as: :json
            assert_response :ok
            assert_equal "allow", JSON.parse(comment.reload.action)["decision"]
          end

          private

          def auth_headers
            { "Authorization" => "Bearer #{@token.token}" }
          end

          def permission_comment(request_id, tool_name)
            @creative.comments.create!(
              content: "🔐 #{tool_name}", user: @agent, topic: @topic, approver: @user,
              action: JSON.pretty_generate("action" => "claude_channel_permission",
                                           "request_id" => request_id, "tool_name" => tool_name),
              skip_default_user: true, skip_dispatch: true
            )
          end

          # Surfacing the event via agent_events is what allocates ref #1.
          def assign_ref!
            get "/api/v1/mobile/agent_events", params: { device_id: DEVICE }, headers: auth_headers, as: :json
            assert_response :ok
          end
        end
      end
    end
  end
end
