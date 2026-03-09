# frozen_string_literal: true

require_relative "../../../test_helper"

module CollavreCompletionApi
  module Api
    module V1
      class ModelsControllerTest < ActionDispatch::IntegrationTest
        setup do
          @user = users(:one)
          @ai_bot = users(:ai_bot)
          # Make ai_bot owned by user
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

        test "returns models list with valid token" do
          get "/api/v1/models",
              headers: { "Authorization" => "Bearer #{@token.token}" }

          assert_response :success
          body = JSON.parse(response.body)
          assert_equal "list", body["object"]
          assert body["data"].is_a?(Array)

          model_ids = body["data"].map { |m| m["id"] }
          assert_includes model_ids, "bot"
        end

        test "returns 401 without token" do
          get "/api/v1/models"

          assert_response :unauthorized
          body = JSON.parse(response.body)
          assert_equal "missing_token", body.dig("error", "code")
        end

        test "returns 401 with invalid token" do
          get "/api/v1/models",
              headers: { "Authorization" => "Bearer invalid_token_here" }

          assert_response :unauthorized
          body = JSON.parse(response.body)
          assert_equal "invalid_token", body.dig("error", "code")
        end

        test "does not include non-accessible agents" do
          # ai_bot is owned by user one, not searchable
          other_user = users(:two)
          other_token = Doorkeeper::AccessToken.create!(
            application: @app, resource_owner_id: other_user.id,
            scopes: "public", expires_in: 1.hour
          )

          get "/api/v1/models",
              headers: { "Authorization" => "Bearer #{other_token.token}" }

          assert_response :success
          body = JSON.parse(response.body)
          model_ids = body["data"].map { |m| m["id"] }
          refute_includes model_ids, "bot"
        end

        test "includes searchable agents for other users" do
          @ai_bot.update!(searchable: true)
          other_user = users(:two)
          other_token = Doorkeeper::AccessToken.create!(
            application: @app, resource_owner_id: other_user.id,
            scopes: "public", expires_in: 1.hour
          )

          get "/api/v1/models",
              headers: { "Authorization" => "Bearer #{other_token.token}" }

          assert_response :success
          body = JSON.parse(response.body)
          model_ids = body["data"].map { |m| m["id"] }
          assert_includes model_ids, "bot"
        end
      end
    end
  end
end
