require "test_helper"

class CliProxyClientTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :message, :payload, :successful, keyword_init: true) do
    def json
      payload
    end

    def success?
      successful
    end
  end

  class FakeHttpClient
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    %i[get post delete].each do |method|
      define_method(method) do |url, body: nil, headers:|
        @requests << { method: method, url: url, body: body, headers: headers }
        @response
      end
    end
  end

  test "auth session request keeps admin authentication server-side and signs workspace identity" do
    gateway = Struct.new(:admin_key, :identity_secret, :tenant_id) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret", "identity-secret" * 3, "collavre")
    workspace = Struct.new(:proxy_user_id).new("agent-42--user-7")
    response = FakeResponse.new(code: 201, message: "Created", payload: { "status" => "pending" }, successful: true)
    http = FakeHttpClient.new(response)

    result = Collavre::CliProxy::Client.new(gateway: gateway, workspace: workspace, http_client: http)
                                      .create_auth_session(
                                        "codex",
                                        flow: "device-code",
                                        provisioning_url: "https://collavre.example/provision.json"
                                      )

    assert_equal "pending", result.fetch("status")
    request = http.requests.fetch(0)
    assert_equal :post, request.fetch(:method)
    assert_equal "Bearer admin-secret", request.dig(:headers, "Authorization")
    assert_equal "agent-42--user-7", request.dig(:headers, "X-CLI-Proxy-User-ID")
    assert_equal "device-code", JSON.parse(request.fetch(:body)).fetch("flow")
  end

  test "maps proxy error response to a domain error" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    response = FakeResponse.new(
      code: 404,
      message: "Not Found",
      payload: { "error" => { "message" => "Provisioning disabled", "code" => "provisioning_disabled" } },
      successful: false
    )
    client = Collavre::CliProxy::Client.new(gateway: gateway, http_client: FakeHttpClient.new(response))

    error = assert_raises(Collavre::CliProxy::Client::Error) { client.provision_status }

    assert_equal 404, error.status
    assert_equal "provisioning_disabled", error.code
  end

  test "sends a completion key as the mapped proxy user key" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    response = FakeResponse.new(code: 200, message: "OK", payload: { "data" => [] }, successful: true)
    http = FakeHttpClient.new(response)

    Collavre::CliProxy::Client.new(gateway: gateway, user_key: "completion-secret", http_client: http).engines

    request = http.requests.fetch(0)
    assert_equal "Bearer admin-secret", request.dig(:headers, "Authorization")
    assert_equal "completion-secret", request.dig(:headers, "X-CLI-Proxy-User-Key")
    assert_nil request.dig(:headers, "X-CLI-Proxy-User-ID")
  end

  test "maps blocked regular-user endpoints without making a request" do
    owner = users(:two)
    gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: "Blocked proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin-secret",
      completion_key: "completion-secret"
    )
    http = FakeHttpClient.new(nil)
    http.define_singleton_method(:get) do |*, **|
      raise Collavre::CliProxy::EndpointPolicy::UnsafeEndpoint
    end

    error = assert_raises(Collavre::CliProxy::Client::Error) do
      Collavre::CliProxy::Client.new(gateway: gateway, http_client: http).engines
    end

    assert_equal "unsafe_proxy_endpoint", error.code
    assert_equal I18n.t("collavre.agent_gateways.unsafe_endpoint"), error.message
  end

  test "default client applies endpoint policy only to non-admin owners" do
    regular_gateway = build_gateway(owner: users(:two), name: "Regular proxy", base_url: "https://proxy.example.com")
    admin_gateway = build_gateway(owner: users(:one), name: "Admin proxy", base_url: "http://127.0.0.1:3456")

    regular_http = Collavre::CliProxy::Client.new(gateway: regular_gateway).instance_variable_get(:@http_client)
    admin_http = Collavre::CliProxy::Client.new(gateway: admin_gateway).instance_variable_get(:@http_client)

    assert_instance_of Collavre::CliProxy::EndpointPolicy, regular_http.instance_variable_get(:@endpoint_policy)
    assert_nil admin_http.instance_variable_get(:@endpoint_policy)
  end

  private

  def build_gateway(owner:, name:, base_url:)
    Collavre::AgentGateway.create!(
      owner: owner,
      name: name,
      base_url: base_url,
      admin_key: "admin-secret",
      completion_key: "completion-secret"
    )
  end
end
