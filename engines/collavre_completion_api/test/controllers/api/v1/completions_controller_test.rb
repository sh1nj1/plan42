# frozen_string_literal: true

require_relative "../../../test_helper"

module CollavreCompletionApi
  module Api
    module V1
      class CompletionsControllerTest < ActionDispatch::IntegrationTest
        setup do
          @user = users(:one)
          @ai_bot = users(:ai_bot)
          @ai_bot.update!(created_by_id: @user.id)

          @app = Doorkeeper::Application.create!(
            name: "Test", redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
            owner: @user, confidential: true, scopes: "public"
          )
          @token = Doorkeeper::AccessToken.create!(
            application: @app, resource_owner_id: @user.id,
            scopes: "public", expires_in: 1.hour
          )
        end

        test "returns 401 without authentication" do
          post "/api/v1/chat/completions",
               params: { model: "collavre/#{@ai_bot.id}", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: { "CONTENT_TYPE" => "application/json" }

          assert_response :unauthorized
        end

        test "returns 400 with empty messages" do
          post "/api/v1/chat/completions",
               params: { model: "collavre/#{@ai_bot.id}", messages: [] }.to_json,
               headers: auth_headers

          assert_response :bad_request
          body = JSON.parse(response.body)
          assert_match(/messages is required/, body.dig("error", "message"))
        end

        test "returns 400 with non-existent email username model" do
          post "/api/v1/chat/completions",
               params: { model: "nonexistent", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          assert_response :bad_request
          body = JSON.parse(response.body)
          assert_match(/Invalid model/, body.dig("error", "message"))
        end

        test "returns 400 with external model name" do
          post "/api/v1/chat/completions",
               params: { model: "gpt-4", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          assert_response :bad_request
          body = JSON.parse(response.body)
          assert_match(/Invalid model/, body.dig("error", "message"))
        end

        test "resolves agent by email username" do
          post "/api/v1/chat/completions",
               params: { model: "bot", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          # Agent resolved successfully — should not return "Invalid model" error
          body = JSON.parse(response.body)
          refute_equal "Invalid model", body.dig("error", "message")
        end

        test "returns 400 with non-existent agent" do
          post "/api/v1/chat/completions",
               params: { model: "collavre/999999", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: auth_headers

          assert_response :bad_request
        end

        test "returns 400 for non-accessible agent" do
          other_user = users(:two)
          other_token = Doorkeeper::AccessToken.create!(
            application: @app, resource_owner_id: other_user.id,
            scopes: "public", expires_in: 1.hour
          )

          post "/api/v1/chat/completions",
               params: { model: "collavre/#{@ai_bot.id}", messages: [ { role: "user", content: "hi" } ] }.to_json,
               headers: { "Authorization" => "Bearer #{other_token.token}", "CONTENT_TYPE" => "application/json" }

          assert_response :bad_request
        end

        test "build_system_prompt uses the canonical profile prompt, not the stale column" do
          # A directly-edited profile Creative makes data["markdown_source"] canonical
          # while the legacy system_prompt column goes stale.
          @ai_bot.update!(system_prompt: "CANONICAL PROFILE PROMPT")
          @ai_bot.sync_profile_system_prompt!
          @ai_bot.update_column(:system_prompt, "STALE COLUMN PROMPT")

          controller = ::CollavreCompletionApi::Api::V1::Chat::CompletionsController.new
          def controller.collavre_creative = nil

          prompt = controller.send(:build_system_prompt, [], @ai_bot.reload)

          assert_includes prompt, "CANONICAL PROFILE PROMPT"
          refute_includes prompt, "STALE COLUMN PROMPT"
        end

        private

        def auth_headers
          { "Authorization" => "Bearer #{@token.token}", "CONTENT_TYPE" => "application/json" }
        end
      end
    end
  end
end
