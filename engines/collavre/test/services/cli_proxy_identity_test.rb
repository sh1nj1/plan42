require "test_helper"

class CliProxyIdentityTest < ActiveSupport::TestCase
  Workspace = Struct.new(:proxy_credential_id, :proxy_workspace_id)

  test "signs the exact proxy v2 request identity contract" do
    gateway = Struct.new(:identity_secret, :tenant_id).new("secret" * 8, "collavre")
    workspace = Workspace.new("user-7", "agent-42")
    at = Time.at(1_786_224_000)

    headers = Collavre::CliProxy::Identity.headers(
      gateway: gateway,
      workspace: workspace,
      method: :post,
      path: "/v1/chat/completions",
      at: at
    )

    payload = "v2\nPOST\n/v1/chat/completions\n#{at.to_i}\ncollavre\nuser-7\nagent-42"
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", gateway.identity_secret, payload),
                 headers.fetch("X-CLI-Proxy-Identity-Signature")
    assert_equal "collavre", headers.fetch("X-CLI-Proxy-Tenant-ID")
    assert_equal "user-7", headers.fetch("X-CLI-Proxy-User-ID")
    assert_equal "agent-42", headers.fetch("X-CLI-Proxy-Workspace-ID")
  end

  test "the workspace axis is covered by the signature" do
    gateway = Struct.new(:identity_secret, :tenant_id).new("secret" * 8, "collavre")
    at = Time.at(1_786_224_000)

    signature = lambda do |workspace_id|
      Collavre::CliProxy::Identity.headers(
        gateway: gateway,
        workspace: Workspace.new("user-7", workspace_id),
        method: :get,
        path: "/v1/provision",
        at: at
      ).fetch("X-CLI-Proxy-Identity-Signature")
    end

    refute_equal signature.call("agent-42"), signature.call("agent-43")
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
