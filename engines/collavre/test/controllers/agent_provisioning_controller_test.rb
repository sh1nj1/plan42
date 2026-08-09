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
    stored = ActiveRecord::Base.connection.select_one(
      "SELECT manifest_token, manifest_token_digest FROM agent_workspaces WHERE id = #{@workspace.id}"
    )

    [ "invalid-token", stored.fetch("manifest_token"), stored.fetch("manifest_token_digest") ].each do |token|
      get collavre.agent_provision_manifest_path(agent_id: @agent.id, token: token)
      assert_response :not_found
    end
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

  test "Rails silences access logs for paths containing manifest capabilities" do
    middleware = Rails.application.middleware.find do |entry|
      entry.klass == Collavre::SensitiveRequestSilencer &&
        entry.args == [ { path: Collavre::Engine::PROVISIONING_CAPABILITY_PATH } ]
    end
    assert_not_nil middleware

    manifest_path = collavre.agent_provision_manifest_path(
      agent_id: @agent.id,
      token: @workspace.manifest_token
    )
    config_path = collavre.agent_provision_config_path(
      agent_id: @agent.id,
      token: @workspace.manifest_token,
      sha256: "a" * 64
    )
    malformed_config_path = config_path.sub("a" * 64, "NOT-A-DIGEST")
    truncated_path = manifest_path.sub(%r{/provision\.json\z}, "")
    skill_path = collavre.agent_provision_skill_path(sha256: "a" * 64)

    assert_match Collavre::Engine::PROVISIONING_CAPABILITY_PATH, manifest_path
    assert_match Collavre::Engine::PROVISIONING_CAPABILITY_PATH, config_path
    assert_match Collavre::Engine::PROVISIONING_CAPABILITY_PATH, malformed_config_path
    assert_match Collavre::Engine::PROVISIONING_CAPABILITY_PATH, truncated_path
    assert_no_match Collavre::Engine::PROVISIONING_CAPABILITY_PATH, skill_path

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)

    Rails.stub(:logger, logger) do
      get malformed_config_path
    end
    assert_response :not_found
    refute_includes output.string, @workspace.manifest_token

    output.truncate(0)
    output.rewind
    error_logger = ->(_env) do
      Rails.logger.error("failed capability request #{@workspace.manifest_token}")
      [ 500, {}, [] ]
    end
    silencer = Collavre::SensitiveRequestSilencer.new(
      error_logger,
      path: Collavre::Engine::PROVISIONING_CAPABILITY_PATH
    )
    Rails.stub(:logger, logger) do
      silencer.call("PATH_INFO" => manifest_path)
    end
    assert_empty output.string

    output.truncate(0)
    output.rewind
    Rails.stub(:logger, logger) do
      get truncated_path
    end
    assert_response :not_found
    refute_includes output.string, @workspace.manifest_token

    output.truncate(0)
    output.rewind
    Rails.stub(:logger, logger) do
      get skill_path
    end
    assert_includes output.string, skill_path
  end
end
