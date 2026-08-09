require "test_helper"

class CliProxyEndpointPolicyTest < ActiveSupport::TestCase
  class FakeResolver
    def initialize(addresses)
      @addresses = addresses
    end

    def getaddresses(_host)
      @addresses
    end
  end

  test "accepts public HTTPS addresses" do
    policy = policy_for("8.8.8.8", "2606:4700:4700::1111")

    assert_equal [ "8.8.8.8", "2606:4700:4700::1111" ], policy.resolve!("https://proxy.example.com/v1")
  end

  test "rejects non-HTTPS, unresolved, private, reserved, and mixed addresses" do
    assert_raises(Collavre::CliProxy::EndpointPolicy::UnsafeEndpoint) do
      policy_for("8.8.8.8").resolve!("http://proxy.example.com")
    end
    assert_raises(Collavre::CliProxy::EndpointPolicy::UnsafeEndpoint) do
      policy_for.resolve!("https://proxy.example.com")
    end

    [
      [ "127.0.0.1" ],
      [ "169.254.169.254" ],
      [ "10.0.0.1" ],
      [ "192.0.2.10" ],
      [ "::1" ],
      [ "fc00::1" ],
      [ "8.8.8.8", "192.168.1.1" ]
    ].each do |addresses|
      assert_raises(Collavre::CliProxy::EndpointPolicy::UnsafeEndpoint, addresses.inspect) do
        policy_for(*addresses).resolve!("https://proxy.example.com")
      end
    end
  end

  test "literal preflight rejects local targets without DNS" do
    policy = policy_for

    assert policy.safe_literal?("https://8.8.8.8")
    assert policy.safe_literal?("https://proxy.example.com")
    assert_not policy.safe_literal?("http://proxy.example.com")
    assert_not policy.safe_literal?("https://127.0.0.1")
    assert_not policy.safe_literal?("https://localhost")
    assert_not policy.safe_literal?("https://proxy.localhost")
  end

  test "Faraday adapter pins the connection to the validated address" do
    resolved_policy = Minitest::Mock.new
    resolved_policy.expect(:resolve!, [ "8.8.8.8" ], [ URI("https://proxy.example.com/v1") ])
    adapter = Collavre::CliProxy::SafeNetHttpAdapter.new

    http = Collavre::CliProxy::EndpointPolicy.stub(:new, resolved_policy) do
      adapter.send(:net_http_connection, url: URI("https://proxy.example.com/v1"))
    end

    assert_equal "proxy.example.com", http.address
    assert_equal "8.8.8.8", http.ipaddr
    assert_equal 443, http.port
    resolved_policy.verify
  end

  private

  def policy_for(*addresses)
    Collavre::CliProxy::EndpointPolicy.new(resolver: FakeResolver.new(addresses))
  end
end
