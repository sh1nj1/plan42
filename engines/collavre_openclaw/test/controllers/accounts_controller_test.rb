require "test_helper"

module CollavreOpenclaw
  class AccountsControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    setup do
      @admin = User.create!(
        email: "admin-openclaw-test@example.com",
        password: "password123",
        name: "Admin User",
        system_admin: true
      )
      @ai_user = User.create!(
        email: "ai-openclaw-test@example.com",
        password: "password123",
        name: "AI Agent",
        creator: @admin
      )
      @account = OpenclawAccount.create!(
        user: @ai_user,
        gateway_url: "https://test-gateway.com",
        api_token: "test-secret-token"
      )

      # Sign in as admin
      post "/session", params: { email: @admin.email, password: "password123" }
    end

    teardown do
      @account&.destroy
      @ai_user&.destroy
      @admin&.destroy
    end

    test "test_connection with successful connection" do
      # Mock successful response
      stub_request(:get, "https://test-gateway.com/health")
        .to_return(status: 200, body: "OK")

      post test_connection_account_path(@account)

      assert_redirected_to edit_account_path(@account)
      follow_redirect!
      assert_match /success/i, flash[:notice]
    end

    test "test_connection with failed connection" do
      # Mock failed response
      stub_request(:get, "https://test-gateway.com/health")
        .to_return(status: 500, body: "Internal Server Error")
      stub_request(:post, "https://test-gateway.com/v1/chat/completions")
        .to_return(status: 500, body: "Internal Server Error")

      post test_connection_account_path(@account)

      assert_redirected_to edit_account_path(@account)
      follow_redirect!
      assert flash[:alert].present?
    end

    test "test_connection with authentication failure" do
      stub_request(:get, "https://test-gateway.com/health")
        .to_return(status: 401, body: "Unauthorized")
      stub_request(:post, "https://test-gateway.com/v1/chat/completions")
        .to_return(status: 401, body: "Unauthorized")

      post test_connection_account_path(@account)

      assert_redirected_to edit_account_path(@account)
      follow_redirect!
      assert_match /authentication|auth/i, flash[:alert]
    end

    test "test_connection returns JSON when requested" do
      stub_request(:get, "https://test-gateway.com/health")
        .to_return(status: 200, body: "OK")

      post test_connection_account_path(@account), as: :json

      assert_response :ok
      json = JSON.parse(response.body)
      assert json["success"]
      assert json["message"].present?
    end

    test "clear_token removes the API token" do
      assert @account.token_configured?

      delete clear_token_account_path(@account)

      assert_redirected_to edit_account_path(@account)
      follow_redirect!
      assert_match /cleared|삭제/i, flash[:notice]

      @account.reload
      assert_not @account.token_configured?
    end

    test "edit page shows token status when configured" do
      assert @account.token_configured?

      get edit_account_path(@account)

      assert_response :ok
      # The page should show token is configured
      assert_select ".token-status--configured" do
        assert_select ".token-status__text"
        assert_select ".token-status__clear-btn"
      end
    end

    test "edit page shows token not configured when empty" do
      @account.update!(api_token: nil)

      get edit_account_path(@account)

      assert_response :ok
      assert_select ".token-status--not-configured"
    end

    test "edit page has test connection button" do
      get edit_account_path(@account)

      assert_response :ok
      assert_select "form[action=?]", test_connection_account_path(@account)
    end
  end
end
