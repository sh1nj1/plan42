# frozen_string_literal: true

require "test_helper"

module CollavreGithub
  module Api
    class TokensControllerTest < ActionDispatch::IntegrationTest
      setup do
        @user = users(:one)
        @other_user = users(:two)

        # Create Doorkeeper OAuth app and token
        @app = Doorkeeper::Application.create!(
          name: "Test", redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
          owner: @user, confidential: true, scopes: "public"
        )
        @oauth_token = Doorkeeper::AccessToken.create!(
          application: @app, resource_owner_id: @user.id,
          scopes: "public", expires_in: 1.hour
        )

        # GitHub account for the user
        @github_account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "12345",
          login: "testuser",
          name: "Test User",
          token: "gho_test_token_abc123"
        )

        # Creative hierarchy: project (with integration) > task
        @project = creatives(:tshirt)
        @task = Collavre::Creative.create!(
          user: @user,
          description: "Task under project",
          parent: @project
        )

        # GitHub integration on the project
        @repo_link = CollavreGithub::RepositoryLink.create!(
          creative: @project,
          github_account: @github_account,
          repository_full_name: "VReRV/plan42"
        )
      end

      test "returns 401 without authentication" do
        get "/github/api/token", params: { creative_id: @task.id }

        assert_response :unauthorized
      end

      test "returns 404 when creative not found" do
        get "/github/api/token",
            params: { creative_id: 999999 },
            headers: auth_headers

        assert_response :not_found
        assert_match(/Creative not found/, response.parsed_body["error"])
      end

      test "returns 403 when user lacks write permission" do
        # Create token for other_user who has no write access
        other_token = Doorkeeper::AccessToken.create!(
          application: @app, resource_owner_id: @other_user.id,
          scopes: "public", expires_in: 1.hour
        )

        get "/github/api/token",
            params: { creative_id: @task.id },
            headers: { "Authorization" => "Bearer #{other_token.token}" }

        assert_response :forbidden
        assert_match(/Insufficient permission/, response.parsed_body["error"])
      end

      test "returns 404 when no GitHub integration in ancestor chain" do
        # Creative without any GitHub integration in its tree
        standalone = Collavre::Creative.create!(
          user: @user,
          description: "Standalone creative"
        )

        get "/github/api/token",
            params: { creative_id: standalone.id },
            headers: auth_headers

        assert_response :not_found
        assert_match(/No GitHub integration/, response.parsed_body["error"])
      end

      test "returns 404 when user has no GitHub account" do
        # Create a second github account to keep the repo link alive
        other_account = CollavreGithub::Account.create!(
          user: @other_user,
          github_uid: "99999",
          login: "otheruser",
          name: "Other User",
          token: "gho_other_token"
        )
        @repo_link.update!(github_account: other_account)
        @github_account.destroy!

        get "/github/api/token",
            params: { creative_id: @task.id },
            headers: auth_headers

        assert_response :not_found
        assert_match(/GitHub account not linked/, response.parsed_body["error"])
      end

      test "returns token for child creative when integration is on parent" do
        get "/github/api/token",
            params: { creative_id: @task.id },
            headers: auth_headers

        assert_response :success
        body = response.parsed_body
        assert_equal "gho_test_token_abc123", body["token"]
        assert_equal "VReRV/plan42", body["repo"]
      end

      test "returns token for creative with direct integration" do
        get "/github/api/token",
            params: { creative_id: @project.id },
            headers: auth_headers

        assert_response :success
        body = response.parsed_body
        assert_equal "gho_test_token_abc123", body["token"]
        assert_equal "VReRV/plan42", body["repo"]
      end

      private

      def auth_headers
        { "Authorization" => "Bearer #{@oauth_token.token}" }
      end
    end
  end
end
