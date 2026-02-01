require "test_helper"

module CollavreOpenclaw
  class OpenclawAccountTest < ActiveSupport::TestCase
    test "validates presence of gateway_url" do
      account = OpenclawAccount.new(gateway_url: nil)
      assert_not account.valid?
      assert_includes account.errors[:gateway_url], "can't be blank"
    end

    test "api_endpoint builds correct URL" do
      account = OpenclawAccount.new(gateway_url: "https://my-gateway.com")
      assert_equal "https://my-gateway.com/v1/chat/completions", account.api_endpoint
    end

    test "api_endpoint handles URL with path" do
      account = OpenclawAccount.new(gateway_url: "https://my-gateway.com/some/path")
      assert_equal "https://my-gateway.com/v1/chat/completions", account.api_endpoint
    end

    test "token_configured? returns true when token is present" do
      account = OpenclawAccount.new(gateway_url: "https://example.com", api_token: "secret_token")
      assert account.token_configured?
    end

    test "token_configured? returns false when token is blank" do
      account = OpenclawAccount.new(gateway_url: "https://example.com", api_token: nil)
      assert_not account.token_configured?

      account.api_token = ""
      assert_not account.token_configured?
    end

    test "clear_token! removes the api_token" do
      user = User.create!(
        email: "clear-token-test-#{SecureRandom.hex(4)}@example.com",
        password: "password123",
        name: "Test User"
      )
      account = OpenclawAccount.create!(
        user: user,
        gateway_url: "https://example.com",
        api_token: "secret_token"
      )

      assert account.token_configured?
      account.clear_token!
      assert_not account.token_configured?
      assert_nil account.reload.api_token
    ensure
      account&.destroy
      user&.destroy
    end

    test "test_connection returns error when gateway_url is blank" do
      account = OpenclawAccount.new(gateway_url: nil)
      result = account.test_connection

      assert_not result[:success]
      assert_equal "Gateway URL not configured", result[:message]
    end

    test "test_connection returns error for invalid URL" do
      account = OpenclawAccount.new(gateway_url: "not-a-valid-url")
      result = account.test_connection

      assert_not result[:success]
      # Could be "Invalid URL" or connection error depending on how URI parses it
      assert result[:message].present?
    end

    test "test_connection returns connection failed for unreachable host" do
      account = OpenclawAccount.new(gateway_url: "https://nonexistent.invalid.host.example.com")
      result = account.test_connection

      assert_not result[:success]
      assert_includes [ "Connection failed", "Connection timeout", "Error" ], result[:message]
    end

    # Agent ID and provisioning tests

    test "agent_provisioned? returns false when agent_id is blank" do
      account = OpenclawAccount.new(gateway_url: "https://example.com")
      assert_not account.agent_provisioned?
    end

    test "agent_provisioned? returns false when agent_provisioned_at is nil" do
      account = OpenclawAccount.new(gateway_url: "https://example.com", agent_id: "my-agent")
      assert_not account.agent_provisioned?
    end

    test "agent_provisioned? returns true when both agent_id and agent_provisioned_at are present" do
      account = OpenclawAccount.new(
        gateway_url: "https://example.com",
        agent_id: "my-agent"
      )
      # Simulate provisioned state without hitting DB
      account.agent_provisioned_at = Time.current
      assert account.agent_provisioned?
    end

    test "provision_agent! returns error when agent_id is blank" do
      account = OpenclawAccount.new(gateway_url: "https://example.com")
      result = account.provision_agent!

      assert_not result[:success]
      assert_equal "No agent_id configured", result[:message]
    end

    test "provision_agent! returns error when gateway_url is blank" do
      account = OpenclawAccount.new(agent_id: "my-agent")
      result = account.provision_agent!

      assert_not result[:success]
      assert_equal "Gateway URL not configured", result[:message]
    end

    test "provision_agent! returns connection error for unreachable host" do
      account = OpenclawAccount.new(
        gateway_url: "https://nonexistent.invalid.host.example.com",
        agent_id: "my-agent"
      )
      result = account.provision_agent!

      assert_not result[:success]
      assert result[:message].present?
    end

    test "check_agent_exists returns error when agent_id is blank" do
      account = OpenclawAccount.new(gateway_url: "https://example.com")
      result = account.check_agent_exists

      assert_not result[:exists]
      assert_equal "No agent_id configured", result[:message]
    end

    test "check_agent_exists returns error when gateway_url is blank" do
      account = OpenclawAccount.new(agent_id: "my-agent")
      result = account.check_agent_exists

      assert_not result[:exists]
      assert_equal "Gateway URL not configured", result[:message]
    end
  end
end
