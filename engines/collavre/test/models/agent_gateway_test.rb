require "test_helper"

class AgentGatewayTest < ActiveSupport::TestCase
  setup do
    @owner = users(:two)
  end

  test "encrypts secrets and validates per-user identity secret" do
    gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Personal proxy",
      base_url: "https://proxy.example.com/",
      admin_key: "admin-secret",
      completion_key: "completion-secret",
      identity_secret: "i" * 32,
      workspace_mode: :per_user
    )

    assert_equal "https://proxy.example.com", gateway.base_url
    assert_equal "https://proxy.example.com/v1", gateway.completion_base_url
    stored = Collavre::AgentGateway.connection.select_one(
      "SELECT admin_key, completion_key, identity_secret FROM agent_gateways WHERE id = #{gateway.id}"
    )
    assert_not_equal "admin-secret", stored.fetch("admin_key")
    assert_not_equal "completion-secret", stored.fetch("completion_key")
    assert_not_equal "i" * 32, stored.fetch("identity_secret")

    gateway.identity_secret = "short"
    assert_not gateway.valid?
    assert gateway.errors[:identity_secret].present?
  end

  test "identity secret is required for per-user mode and optional for shared mode" do
    gateway = build_gateway(workspace_mode: :per_user, identity_secret: nil)
    assert_not gateway.valid?
    assert_includes gateway.errors.details[:identity_secret].pluck(:error), :blank

    gateway.workspace_mode = :shared
    assert gateway.valid?, gateway.errors.full_messages.to_sentence

    gateway.identity_secret = "short"
    assert_not gateway.valid?
    assert_includes gateway.errors.details[:identity_secret].pluck(:error), :too_short
  end

  test "identity secret is required before a shared gateway can serve multiple agents" do
    gateway = build_gateway(identity_secret: "s" * 32)
    gateway.save!
    create_agent(gateway)
    create_agent(gateway)

    gateway.identity_secret = nil

    assert_not gateway.valid?
    assert_includes gateway.errors.details[:identity_secret].pluck(:error), :blank
  end

  test "validation messages are translated in every supported locale" do
    %i[en ko].each do |locale|
      I18n.with_locale(locale) do
        gateway = build_gateway(name: "", base_url: "file:///tmp/proxy", workspace_mode: :per_user, identity_secret: "short")
        assert_not gateway.valid?

        messages = gateway.errors.full_messages
        assert messages.any?, "expected validation errors for locale #{locale}"
        messages.each do |message|
          assert_no_match(/translation missing/i, message, "untranslated validation message in #{locale}: #{message}")
        end
      end
    end
  end

  test "rejects non-http and credential-bearing URLs" do
    gateway = build_gateway(base_url: "file:///tmp/proxy")
    assert_not gateway.valid?

    gateway.base_url = "https://user:password@proxy.example.com"
    assert_not gateway.valid?
  end

  test "normalizes a versioned completion URL for control API requests" do
    gateway = build_gateway(base_url: "https://proxy.example.com/deployment/v1")

    assert gateway.valid?, gateway.errors.full_messages.to_sentence
    assert_equal "https://proxy.example.com/deployment/v1", gateway.completion_base_url
    assert_equal "https://proxy.example.com/deployment/v1/auth/engines", gateway.proxy_path("/v1/auth/engines")
  end

  test "regular owners require public HTTPS while system administrators may use internal HTTP endpoints" do
    regular_gateway = build_gateway(base_url: "http://127.0.0.1:3456")
    assert_not regular_gateway.valid?
    assert_includes regular_gateway.errors.details[:base_url].pluck(:error), :unsafe

    regular_gateway.base_url = "https://192.168.1.20"
    assert_not regular_gateway.valid?
    assert_includes regular_gateway.errors.details[:base_url].pluck(:error), :unsafe

    admin_gateway = build_gateway(owner: users(:one), base_url: "http://127.0.0.1:3456")
    assert admin_gateway.valid?, admin_gateway.errors.full_messages.to_sentence
  end

  test "switching to shared preserves the owner workspace and revokes the others" do
    gateway = build_gateway(identity_secret: "s" * 32)
    gateway.save!
    agent = create_agent(gateway)
    shared_workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: nil)
    gateway.update!(workspace_mode: :per_user)
    owner_workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: @owner)
    other_workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: users(:three))
    owner_manifest_token = owner_workspace.manifest_token
    owner_callback_token = owner_workspace.callback_token
    owner_access_token = Doorkeeper::AccessToken.by_token(owner_callback_token)

    gateway.update!(workspace_mode: :shared)

    assert_equal shared_workspace, owner_workspace
    assert_nil owner_workspace.reload.user_id
    assert_equal "agent-#{agent.id}", owner_workspace.proxy_user_id
    assert_equal owner_manifest_token, owner_workspace.manifest_token
    assert_not_equal owner_callback_token, owner_workspace.callback_token
    assert_predicate owner_access_token.reload, :revoked?
    shared_access_token = Doorkeeper::AccessToken.by_token(owner_workspace.callback_token)
    assert_equal agent.id, shared_access_token.resource_owner_id
    assert_predicate shared_access_token, :accessible?
    assert_not Collavre::AgentWorkspace.exists?(other_workspace.id)
    assert_equal owner_workspace, Collavre::AgentWorkspace.resolve!(agent: agent, user: nil)
  end

  test "switching to per-user immediately reassigns the shared workspace to the owner" do
    gateway = build_gateway(identity_secret: "s" * 32)
    gateway.save!
    agent = create_agent(gateway)
    shared_workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: nil)
    shared_manifest_token = shared_workspace.manifest_token
    shared_callback_token = shared_workspace.callback_token
    shared_access_token = Doorkeeper::AccessToken.by_token(shared_callback_token)

    gateway.update!(workspace_mode: :per_user)

    owner_workspace = shared_workspace.reload
    assert_equal @owner, owner_workspace.user
    assert_equal "agent-#{agent.id}", owner_workspace.proxy_user_id
    assert_equal shared_manifest_token, owner_workspace.manifest_token
    assert_not_equal shared_callback_token, owner_workspace.callback_token
    assert_predicate shared_access_token.reload, :revoked?
    owner_access_token = Doorkeeper::AccessToken.by_token(owner_workspace.callback_token)
    assert_equal @owner.id, owner_access_token.resource_owner_id
    assert_predicate owner_access_token, :accessible?
    assert_equal owner_workspace, Collavre::AgentWorkspace.resolve!(agent: agent, user: @owner)
  end

  test "changing the proxy or tenant revokes existing workspace capabilities" do
    {
      base_url: "https://replacement-proxy.example.com",
      tenant_id: "replacement-tenant"
    }.each do |attribute, replacement|
      gateway = build_gateway(identity_secret: "s" * 32)
      gateway.save!
      agent = create_agent(gateway)
      workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: nil)
      manifest_token = workspace.manifest_token
      callback_token = workspace.callback_token
      access_token = Doorkeeper::AccessToken.by_token(callback_token)

      gateway.update!(attribute => replacement)

      assert_not Collavre::AgentWorkspace.exists?(workspace.id), "expected #{attribute} change to revoke the workspace"
      assert_predicate access_token.reload, :revoked?
      assert_raises(ActiveRecord::RecordNotFound) do
        Collavre::AgentWorkspace.find_by_manifest_token!(agent_id: agent.id, token: manifest_token)
      end

      replacement_workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: nil)
      assert_not_equal workspace.id, replacement_workspace.id
      assert_not_equal manifest_token, replacement_workspace.manifest_token
      assert_not_equal callback_token, replacement_workspace.callback_token
      assert_predicate Doorkeeper::AccessToken.by_token(replacement_workspace.callback_token), :accessible?
    end
  end

  private

  def build_gateway(overrides = {})
    Collavre::AgentGateway.new({
      owner: @owner,
      name: "Proxy #{SecureRandom.hex(3)}",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    }.merge(overrides))
  end

  def create_agent(gateway)
    Collavre::User.create!(
      name: "CLI Agent",
      email: "cli-#{SecureRandom.hex(4)}@ai.local",
      password: SecureRandom.hex(24),
      system_prompt: "Help",
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: @owner.id,
      agent_gateway: gateway
    )
  end
end
