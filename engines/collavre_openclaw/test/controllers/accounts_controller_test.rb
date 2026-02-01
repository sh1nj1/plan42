require "test_helper"

module CollavreOpenclaw
  class AccountsControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    # Note: These are unit tests for the model methods that the controller uses.
    # Full integration tests with authentication are complex due to engine routing.
    # System tests or manual testing should verify the complete UI flow.

    test "OpenclawAccount#test_connection returns proper structure" do
      account = OpenclawAccount.new(
        gateway_url: "https://test-gateway.example.com",
        api_token: "test-token"
      )

      result = account.test_connection

      assert result.is_a?(Hash)
      assert result.key?(:success)
      assert result.key?(:message)
    end

    test "OpenclawAccount#test_connection handles unreachable host" do
      account = OpenclawAccount.new(
        gateway_url: "https://192.0.2.1",  # TEST-NET-1, guaranteed unreachable
        api_token: "test-token"
      )

      result = account.test_connection

      assert_not result[:success]
      assert result[:message].present?
    end

    test "OpenclawAccount#test_connection handles missing gateway_url" do
      account = OpenclawAccount.new(
        gateway_url: nil,
        api_token: "test-token"
      )

      result = account.test_connection

      assert_not result[:success]
      assert_equal "Gateway URL not configured", result[:message]
    end

    test "OpenclawAccount#token_configured? returns true when token present" do
      account = OpenclawAccount.new(
        gateway_url: "https://example.com",
        api_token: "secret"
      )

      assert account.token_configured?
    end

    test "OpenclawAccount#token_configured? returns false when token absent" do
      account = OpenclawAccount.new(
        gateway_url: "https://example.com",
        api_token: nil
      )

      assert_not account.token_configured?
    end

    test "routes include test_connection" do
      account_id = 1
      expected_path = "/openclaw/accounts/#{account_id}/test_connection"
      assert_equal expected_path, test_connection_account_path(account_id)
    end

    test "routes include clear_token" do
      account_id = 1
      expected_path = "/openclaw/accounts/#{account_id}/clear_token"
      assert_equal expected_path, clear_token_account_path(account_id)
    end
  end
end
