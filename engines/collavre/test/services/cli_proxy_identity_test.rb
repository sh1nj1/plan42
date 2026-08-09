require "test_helper"

class CliProxyIdentityTest < ActiveSupport::TestCase
  test "signs the exact proxy request identity contract" do
    gateway = Struct.new(:identity_secret, :tenant_id).new("secret" * 8, "collavre")
    workspace = Struct.new(:proxy_user_id).new("agent-42--user-7")
    at = Time.at(1_786_224_000)

    headers = Collavre::CliProxy::Identity.headers(
      gateway: gateway,
      workspace: workspace,
      method: :post,
      path: "/v1/chat/completions",
      at: at
    )

    payload = "v1\nPOST\n/v1/chat/completions\n#{at.to_i}\ncollavre\nagent-42--user-7"
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", gateway.identity_secret, payload),
                 headers.fetch("X-CLI-Proxy-Identity-Signature")
    assert_equal "collavre", headers.fetch("X-CLI-Proxy-Tenant-ID")
    assert_equal "agent-42--user-7", headers.fetch("X-CLI-Proxy-User-ID")
  end

  test "omits identity headers when shared fallback has no secret" do
    gateway = Struct.new(:identity_secret).new(nil)
    assert_empty Collavre::CliProxy::Identity.headers(
      gateway: gateway,
      workspace: Object.new,
      method: :get,
      path: "/v1/auth/engines"
    )
  end
end
