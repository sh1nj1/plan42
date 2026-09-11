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
        raise @response if @response.is_a?(Exception)

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
    workspace = Struct.new(:proxy_credential_id, :proxy_workspace_id).new("user-7", "agent-42")
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
    assert_equal "user-7", request.dig(:headers, "X-CLI-Proxy-User-ID")
    assert_equal "agent-42", request.dig(:headers, "X-CLI-Proxy-Workspace-ID")
    assert_equal "device-code", JSON.parse(request.fetch(:body)).fetch("flow")
  end

  test "submits an optional custom provider base url with the credential" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    response = FakeResponse.new(code: 200, message: "OK", payload: { "status" => "authorized" }, successful: true)
    http = FakeHttpClient.new(response)

    Collavre::CliProxy::Client.new(gateway: gateway, http_client: http)
                              .submit_auth_session("codex_custom", "session-1", "provider-secret", base_url: "https://openrouter.ai/api/v1")

    assert_equal(
      { "value" => "provider-secret", "base_url" => "https://openrouter.ai/api/v1" },
      JSON.parse(http.requests.fetch(0).fetch(:body))
    )
  end

  test "omits an absent custom provider base url" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    response = FakeResponse.new(code: 200, message: "OK", payload: { "status" => "authorized" }, successful: true)
    http = FakeHttpClient.new(response)

    Collavre::CliProxy::Client.new(gateway: gateway, http_client: http)
                              .submit_auth_session("codex", "session-1", "provider-secret")

    assert_equal({ "value" => "provider-secret" }, JSON.parse(http.requests.fetch(0).fetch(:body)))
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

  test "maps an oversized response to a domain error" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    http = FakeHttpClient.new(Collavre::HttpClient::ResponseTooLarge.new("too large"))

    error = assert_raises(Collavre::CliProxy::Client::Error) do
      Collavre::CliProxy::Client.new(gateway: gateway, http_client: http).health_live
    end

    assert_equal "proxy_response_too_large", error.code
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

  test "registers a manifest url so provisioning can be repaired without a login" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    response = FakeResponse.new(code: 200, message: "OK", payload: { "items" => [] }, successful: true)
    http = FakeHttpClient.new(response)

    Collavre::CliProxy::Client.new(gateway: gateway, http_client: http)
                              .provision_register_manifest("https://collavre.example/provision.json")

    request = http.requests.fetch(0)
    assert_equal :post, request.fetch(:method)
    assert_equal "https://proxy.example.com/v1/provision/manifest", request.fetch(:url)
    assert_equal(
      { "url" => "https://collavre.example/provision.json" },
      JSON.parse(request.fetch(:body))
    )
  end

  test "keeps the status of a failure whose body is not json" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    response = FakeResponse.new(code: 404, message: "Not Found", payload: nil, successful: false)
    response.define_singleton_method(:json) { raise JSON::ParserError, "unexpected token at '<html>'" }

    error = assert_raises(Collavre::CliProxy::Client::Error) do
      Collavre::CliProxy::Client.new(gateway: gateway, http_client: FakeHttpClient.new(response))
                                .provision_register_manifest("https://collavre.example/provision.json")
    end

    assert_equal 404, error.status
    assert_nil error.code
    assert_equal "Not Found", error.message
  end

  test "still reports an unparsable success body as an error" do
    gateway = Struct.new(:admin_key) do
      def proxy_path(path)
        "https://proxy.example.com#{path}"
      end
    end.new("admin-secret")
    response = FakeResponse.new(code: 200, message: "OK", payload: nil, successful: true)
    response.define_singleton_method(:json) { raise JSON::ParserError, "unexpected token at '<html>'" }

    error = assert_raises(Collavre::CliProxy::Client::Error) do
      Collavre::CliProxy::Client.new(gateway: gateway, http_client: FakeHttpClient.new(response)).provision_status
    end

    assert_equal "Invalid JSON from CLI proxy", error.message
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

  # /health/ready is unauthenticated, but the proxy withholds per-engine detail
  # from a caller without a completion key — and the admin key is not one.
  test "readiness probe presents the completion key, not the admin key" do
    gateway = build_gateway(owner: users(:two), name: "Ready proxy", base_url: "https://proxy.example.com")
    response = FakeResponse.new(code: 200, message: "OK", payload: { "status" => "ok" }, successful: true)
    http = FakeHttpClient.new(response)

    Collavre::CliProxy::Client.new(gateway: gateway, http_client: http).health_ready

    request = http.requests.fetch(0)
    assert_equal "https://proxy.example.com/health/ready", request.fetch(:url)
    assert_equal "Bearer completion-secret", request.dig(:headers, "Authorization")
  end

  test "readiness probe sends no credential when the gateway holds no completion key" do
    gateway = Collavre::AgentGateway.create!(
      owner: users(:two), name: "Keyless proxy", base_url: "https://proxy.example.com", admin_key: "admin-secret"
    )
    response = FakeResponse.new(code: 200, message: "OK", payload: { "status" => "degraded" }, successful: true)
    http = FakeHttpClient.new(response)

    Collavre::CliProxy::Client.new(gateway: gateway, http_client: http).health_ready

    assert_nil http.requests.fetch(0).dig(:headers, "Authorization")
  end

  # 503 is this endpoint's verdict for "every engine is logged out" and carries
  # the same body as a 200. Raising it would discard what the caller probed for.
  test "readiness probe returns the 503 body instead of raising" do
    gateway = build_gateway(owner: users(:two), name: "Down proxy", base_url: "https://proxy.example.com")
    body = { "status" => "down", "engines" => { "ready" => 0, "total" => 2 } }
    http = FakeHttpClient.new(
      FakeResponse.new(code: 503, message: "Service Unavailable", payload: body, successful: false)
    )

    assert_equal body, Collavre::CliProxy::Client.new(gateway: gateway, http_client: http).health_ready
  end

  test "readiness probe still raises a 503 that carries no verdict" do
    gateway = build_gateway(owner: users(:two), name: "Proxied proxy", base_url: "https://proxy.example.com")
    http = FakeHttpClient.new(
      FakeResponse.new(code: 503, message: "Service Unavailable", payload: nil, successful: false)
    )

    error = assert_raises(Collavre::CliProxy::Client::Error) do
      Collavre::CliProxy::Client.new(gateway: gateway, http_client: http).health_ready
    end
    assert_equal 503, error.status
  end

  test "liveness probe is unauthenticated" do
    gateway = build_gateway(owner: users(:two), name: "Live proxy", base_url: "https://proxy.example.com")
    http = FakeHttpClient.new(
      FakeResponse.new(code: 200, message: "OK", payload: { "status" => "ok" }, successful: true)
    )

    Collavre::CliProxy::Client.new(gateway: gateway, http_client: http).health_live

    request = http.requests.fetch(0)
    assert_equal "https://proxy.example.com/health", request.fetch(:url)
    assert_nil request.dig(:headers, "Authorization")
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
