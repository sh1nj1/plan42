require "test_helper"

class AgentProvisioningControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:two)
    @gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Provision proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
    @agent = Collavre::User.create!(
      name: "Provision Agent",
      email: "provision-agent@ai.local",
      password: SecureRandom.hex(24),
      system_prompt: "Help",
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: @owner.id,
      agent_gateway: @gateway
    )
    @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)
  end

  test "public manifest contains fixed skill and workspace config artifacts" do
    get collavre.agent_provision_manifest_path(agent_id: @agent.id, token: @workspace.manifest_token)
    assert_response :success

    manifest = response.parsed_body
    assert_equal "agent-provisioning/v1", manifest.fetch("schema")
    assert_equal [ [ "skill", "collavre" ], [ "config", "collavre" ] ],
                 manifest.fetch("items").map { |item| [ item.fetch("type"), item.fetch("name") ] }

    manifest.fetch("items").each do |item|
      get URI(item.fetch("url")).request_uri
      assert_response :success
      assert_equal item.fetch("sha256"), Digest::SHA256.hexdigest(response.body)
      if item.fetch("type") == "skill"
        assert_includes response.headers["Cache-Control"], "max-age=31536000"
        assert_includes response.headers["Cache-Control"], "public"
        assert_includes response.headers["Cache-Control"], "immutable"
      else
        assert_includes response.headers["Cache-Control"], "no-store"
        assert_includes response.headers["Cache-Control"], "private"
      end
    end
  end

  test "invalid manifest capability is not found" do
    get collavre.agent_provision_manifest_path(agent_id: @agent.id, token: "invalid-token")
    assert_response :not_found
  end

  test "callback token rotation preserves the registered manifest URL" do
    manifest_path = collavre.agent_provision_manifest_path(
      agent_id: @agent.id,
      token: @workspace.manifest_token
    )
    get manifest_path
    old_config = response.parsed_body.fetch("items").find { |item| item.fetch("type") == "config" }

    @workspace.rotate_tokens!

    get manifest_path
    assert_response :success
    new_config = response.parsed_body.fetch("items").find { |item| item.fetch("type") == "config" }
    assert_not_equal old_config.fetch("sha256"), new_config.fetch("sha256")

    get URI(old_config.fetch("url")).request_uri
    assert_response :not_found
    get URI(new_config.fetch("url")).request_uri
    assert_response :success
  end

  test "rate limiting applies only to manifests" do
    cache_key = "rate-limit:collavre/agent_provisioning:127.0.0.1"
    Rails.cache.write(cache_key, 60, expires_in: 1.minute)
    skill = Collavre::AgentProvisioning::Archive.collavre_skill

    get collavre.agent_provision_skill_path(sha256: Digest::SHA256.hexdigest(skill))
    assert_response :success

    get collavre.agent_provision_manifest_path(agent_id: @agent.id, token: @workspace.manifest_token)
    assert_response :too_many_requests
  ensure
    Rails.cache.delete(cache_key) if cache_key
  end
end
