require "test_helper"

module CollavreOpenclaw
  class AccountsControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    setup do
      @admin = User.create!(
        email: "admin-openclaw-test-#{SecureRandom.hex(4)}@example.com",
        password: TEST_PASSWORD,
        name: "Admin User",
        system_admin: true,
        email_verified_at: Time.current
      )
      @ai_user = User.create!(
        email: "ai-openclaw-test-#{SecureRandom.hex(4)}@example.com",
        password: TEST_PASSWORD,
        name: "AI Agent",
        creator: @admin,
        email_verified_at: Time.current
      )
      @account = OpenclawAccount.create!(
        user: @ai_user,
        gateway_url: "https://test-gateway.example.com",
        api_token: "test-secret-token"
      )

      # Sign in as admin using the app's sign_in helper
      sign_in_as(@admin)
    end

    teardown do
      @account&.destroy
      @ai_user&.destroy
      @admin&.destroy
    end

    # Test connection tests - these test the endpoint behavior without mocking HTTP
    # The actual HTTP call will fail (connection refused), which is a valid test case

    test "test_connection endpoint is accessible" do
      post test_connection_account_path(@account)

      # Should redirect back to edit page (either with success or failure flash)
      assert_redirected_to edit_account_path(@account)
    end

    test "test_connection handles unreachable gateway gracefully" do
      # Using a non-routable address that will fail quickly
      @account.update!(gateway_url: "https://192.0.2.1")  # TEST-NET-1, guaranteed unreachable

      post test_connection_account_path(@account)

      assert_redirected_to edit_account_path(@account)
      follow_redirect!
      # Should show an error message
      assert flash[:alert].present?
    end

    test "test_connection returns JSON when requested" do
      post test_connection_account_path(@account), as: :json

      assert_response :ok
      json = JSON.parse(response.body)
      # Will fail because the gateway doesn't exist, but the response format is correct
      assert json.key?("success")
      assert json.key?("message")
    end

    test "clear_token removes the API token" do
      assert @account.token_configured?

      delete clear_token_account_path(@account)

      assert_redirected_to edit_account_path(@account)
      follow_redirect!
      assert flash[:notice].present?

      @account.reload
      assert_not @account.token_configured?
    end

    test "edit page shows token status when configured" do
      assert @account.token_configured?

      get edit_account_path(@account)

      assert_response :ok
      # The page should show token is configured
      assert_select ".token-status--configured"
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

    test "edit page has clear token button when token is configured" do
      get edit_account_path(@account)

      assert_response :ok
      assert_select "form[action=?]", clear_token_account_path(@account)
    end

    test "unauthorized user cannot access test_connection" do
      sign_out
      other_user = User.create!(
        email: "other-user-#{SecureRandom.hex(4)}@example.com",
        password: TEST_PASSWORD,
        name: "Other User",
        email_verified_at: Time.current
      )
      sign_in_as(other_user)

      post test_connection_account_path(@account)

      # Should be redirected due to authorization failure
      assert_response :redirect
    ensure
      other_user&.destroy
    end

    test "unauthorized user cannot clear token" do
      sign_out
      other_user = User.create!(
        email: "other-user-clear-#{SecureRandom.hex(4)}@example.com",
        password: TEST_PASSWORD,
        name: "Other User",
        email_verified_at: Time.current
      )
      sign_in_as(other_user)

      delete clear_token_account_path(@account)

      # Should be redirected due to authorization failure
      assert_response :redirect
      # Token should still be there
      @account.reload
      assert @account.token_configured?
    ensure
      other_user&.destroy
    end
  end
end
