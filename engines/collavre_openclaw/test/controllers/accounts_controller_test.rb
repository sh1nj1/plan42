require "test_helper"

module CollavreOpenclaw
  class AccountsControllerTest < ActionDispatch::IntegrationTest
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

    test "engine routes recognize connection testing action" do
      # Verify route exists by checking the route set directly
      routes = Engine.routes
      route = routes.routes.find { |r| r.defaults[:action] == "test_connection" }
      assert_not_nil route, "test_connection route should be defined"
      assert_equal "accounts", route.defaults[:controller].split("/").last
    end

    test "engine routes recognize token clearing action" do
      # Verify route exists by checking the route set directly
      routes = Engine.routes
      route = routes.routes.find { |r| r.defaults[:action] == "clear_token" }
      assert_not_nil route, "clear_token route should be defined"
      assert_equal "accounts", route.defaults[:controller].split("/").last
    end
  end
end
