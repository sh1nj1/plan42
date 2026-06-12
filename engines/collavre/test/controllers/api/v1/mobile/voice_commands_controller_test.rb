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
          end

          test "voice_commands requires authentication" do
            post "/api/v1/mobile/voice_commands", params: { text: "할 일 정리", device_id: DEVICE }, as: :json
            assert_response :unauthorized
          end

          test "a cold utterance posts to the user's inbox and reports sent" do
            assert_difference -> { Comment.count }, 1 do
              post "/api/v1/mobile/voice_commands",
                params: { text: "오늘 할 일 정리해", device_id: DEVICE }, headers: auth_headers, as: :json
            end
            assert_response :ok
            assert_equal "message_sent", JSON.parse(response.body).dig("action", "type")

            posted = Comment.order(:id).last
            assert_equal "오늘 할 일 정리해", posted.content
            assert_equal @user.id, posted.user_id
            assert Collavre::Creative.inbox_for(@user).id == posted.creative_id,
              "a plain mic press starts work in the user's inbox"
          end

          test "a blank utterance is a no-op" do
            assert_no_difference -> { Comment.count } do
              post "/api/v1/mobile/voice_commands",
                params: { text: "   ", device_id: DEVICE }, headers: auth_headers, as: :json
            end
            assert_response :ok
            assert_equal "noop", JSON.parse(response.body).dig("action", "type")
          end

          private

          def auth_headers
            { "Authorization" => "Bearer #{@token.token}" }
          end
        end
      end
    end
  end
end
