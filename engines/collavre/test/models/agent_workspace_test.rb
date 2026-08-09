require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260809000003_hash_agent_workspace_callback_tokens")
require Rails.root.join("engines/collavre/db/migrate/20260809000004_encrypt_agent_workspace_manifest_tokens")
require Rails.root.join("engines/collavre/db/migrate/20260810000000_split_agent_workspace_identity_axes")

class AgentWorkspaceTest < ActiveSupport::TestCase
  setup do
    @owner = users(:two)
    @other = users(:three)
    @gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Workspace proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "w" * 32,
      workspace_mode: :shared
    )
    @agent = Collavre::User.create!(
      name: "Workspace Agent",
      email: "workspace-agent@ai.local",
      password: SecureRandom.hex(24),
      system_prompt: "Help",
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/codex_local",
      created_by_id: @owner.id,
      agent_gateway: @gateway
    )
  end

  test "shared mode resolves one workspace and usable callback token" do
    first = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    second = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @other)

    assert_equal first, second
    assert_nil first.user
    assert_equal "agent-#{@agent.id}", first.proxy_credential_id
    assert_equal "agent-#{@agent.id}", first.proxy_workspace_id
    assert Doorkeeper::AccessToken.by_token(first.callback_token).accessible?
  end

  test "resolution reloads and locks the gateway before creating a workspace" do
    cached_gateway = @agent.agent_gateway
    assert_predicate cached_gateway, :active?
    Collavre::AgentGateway.where(id: cached_gateway.id).update_all(active: false)

    assert_raises(ArgumentError, match: /inactive/) do
      Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    end
    assert_empty Collavre::AgentWorkspace.where(agent: @agent, agent_gateway: cached_gateway)
  end

  test "resolution reloads and locks the agent before selecting its gateway" do
    cached_gateway = @agent.agent_gateway
    replacement_gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Replacement workspace proxy",
      base_url: "https://replacement-proxy.example.com",
      admin_key: "replacement-admin",
      completion_key: "replacement-completion",
      identity_secret: "r" * 32,
      workspace_mode: :shared
    )
    Collavre::User.where(id: @agent.id).update_all(agent_gateway_id: replacement_gateway.id)

    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)

    assert_equal replacement_gateway, workspace.agent_gateway
    assert_equal replacement_gateway, @agent.agent_gateway
    assert_empty Collavre::AgentWorkspace.where(agent: @agent, agent_gateway: cached_gateway)
  end

  test "resolution locks the gateway before the agent" do
    lock_order = []
    gateway_lock = ->(&block) do
      lock_order << :gateway
      block.call
    end
    agent_lock = ->(&block) do
      lock_order << :agent
      block.call
    end

    Collavre::AgentGateway.stub(:find, @gateway) do
      @gateway.stub(:with_lock, gateway_lock) do
        @agent.stub(:with_lock, agent_lock) do
          Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
        end
      end
    end

    assert_equal [ :gateway, :agent ], lock_order.first(2)
  end

  test "callback token is hashed in Doorkeeper while the plaintext bearer remains usable" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    access_token = Doorkeeper::AccessToken.by_token(workspace.callback_token)
    stored_token = access_token.reload.token

    assert_equal Collavre::HashedAccessTokenLookup.encode(workspace.callback_token), stored_token
    assert_not_equal workspace.callback_token, stored_token
    assert_nil Doorkeeper::AccessToken.by_token(stored_token)
    assert_predicate access_token, :accessible?
  end

  test "manifest capability is encrypted and only its plaintext resolves" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    plaintext = workspace.manifest_token
    stored = workspace.read_attribute_before_type_cast(:manifest_token)

    assert_not_equal plaintext, stored
    assert_equal Digest::SHA256.hexdigest(plaintext), workspace.manifest_token_digest
    assert_equal workspace,
      Collavre::AgentWorkspace.find_by_manifest_token!(agent_id: @agent.id, token: plaintext)
    assert_raises(ActiveRecord::RecordNotFound) do
      Collavre::AgentWorkspace.find_by_manifest_token!(agent_id: @agent.id, token: stored)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      Collavre::AgentWorkspace.find_by_manifest_token!(
        agent_id: @agent.id,
        token: workspace.manifest_token_digest
      )
    end
  end

  test "ordinary Doorkeeper tokens retain plain storage and lookup" do
    application = Doorkeeper::Application.create!(
      owner: @owner,
      name: "Ordinary OAuth client",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      confidential: true,
      scopes: "public"
    )
    access_token = Doorkeeper::AccessToken.create!(
      application: application,
      resource_owner_id: @owner.id,
      scopes: "public"
    )

    assert_equal access_token.token, access_token.reload.token
    assert_equal access_token, Doorkeeper::AccessToken.by_token(access_token.token)
  end

  test "migration hashes and restores legacy workspace callback tokens" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    access_token = Doorkeeper::AccessToken.by_token(workspace.callback_token)
    access_token.update_column(:token, workspace.callback_token)
    migration = HashAgentWorkspaceCallbackTokens.new

    migration.up

    assert_equal Collavre::HashedAccessTokenLookup.encode(workspace.callback_token), access_token.reload.token
    assert_equal access_token, Doorkeeper::AccessToken.by_token(workspace.callback_token)

    migration.down

    assert_equal workspace.callback_token, access_token.reload.token
    assert_equal access_token, Doorkeeper::AccessToken.by_token(workspace.callback_token)
  end

  test "migration encrypts and restores legacy manifest capabilities" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    plaintext = workspace.manifest_token
    connection = ActiveRecord::Base.connection
    connection.execute(
      "UPDATE agent_workspaces SET manifest_token = #{connection.quote(plaintext)} WHERE id = #{workspace.id}"
    )
    migration = EncryptAgentWorkspaceManifestTokens.new

    migration.send(:transform_tokens, encrypt: true)

    stored = connection.select_value("SELECT manifest_token FROM agent_workspaces WHERE id = #{workspace.id}")
    assert_not_equal plaintext, stored
    assert_equal plaintext, workspace.reload.manifest_token
    assert_equal Digest::SHA256.hexdigest(plaintext), workspace.manifest_token_digest

    migration.send(:transform_tokens, encrypt: false)

    assert_equal plaintext,
      connection.select_value("SELECT manifest_token FROM agent_workspaces WHERE id = #{workspace.id}")
  end

  test "per-user mode isolates users and replaces the owner shared identity" do
    shared = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    shared_manifest_token = shared.manifest_token
    shared_callback_token = shared.callback_token
    shared_access_token = Doorkeeper::AccessToken.by_token(shared_callback_token)
    @gateway.update!(workspace_mode: :per_user)

    owner_workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    other_workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @other)

    assert_not_equal shared.id, owner_workspace.id
    assert_equal @owner, owner_workspace.user
    assert_equal "user-#{@owner.id}", owner_workspace.proxy_credential_id
    assert_equal "agent-#{@agent.id}", owner_workspace.proxy_workspace_id
    assert_not_equal shared_manifest_token, owner_workspace.manifest_token
    assert_not_equal shared_callback_token, owner_workspace.callback_token
    assert_predicate shared_access_token.reload, :revoked?
    assert_raises(ActiveRecord::RecordNotFound) do
      Collavre::AgentWorkspace.find_by_manifest_token!(agent_id: @agent.id, token: shared_manifest_token)
    end
    owner_access_token = Doorkeeper::AccessToken.by_token(owner_workspace.callback_token)
    assert_equal @owner.id, owner_access_token.resource_owner_id
    assert_predicate owner_access_token, :accessible?
    assert_equal "user-#{@other.id}", other_workspace.proxy_credential_id
    assert_equal "agent-#{@agent.id}", other_workspace.proxy_workspace_id
    assert_not_equal owner_workspace.callback_token, other_workspace.callback_token
  end

  test "per-user resolution replaces a legacy shared workspace" do
    shared = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    shared_manifest_token = shared.manifest_token
    shared_access_token = Doorkeeper::AccessToken.by_token(shared.callback_token)
    @gateway.update_column(:workspace_mode, Collavre::AgentGateway.workspace_modes.fetch("per_user"))

    owner_workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)

    assert_not_equal shared.id, owner_workspace.id
    assert_equal @owner, owner_workspace.user
    assert_equal "user-#{@owner.id}", owner_workspace.proxy_credential_id
    assert_equal "agent-#{@agent.id}", owner_workspace.proxy_workspace_id
    assert_not_equal shared_manifest_token, owner_workspace.manifest_token
    assert_predicate shared_access_token.reload, :revoked?
    assert_raises(ActiveRecord::RecordNotFound) do
      Collavre::AgentWorkspace.find_by_manifest_token!(agent_id: @agent.id, token: shared_manifest_token)
    end
  end

  test "per-user resolution replaces a legacy owner-associated shared identity" do
    legacy = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    legacy_manifest_token = legacy.manifest_token
    legacy_access_token = Doorkeeper::AccessToken.by_token(legacy.callback_token)
    legacy.update_column(:user_id, @owner.id)
    @gateway.update_column(:workspace_mode, Collavre::AgentGateway.workspace_modes.fetch("per_user"))

    owner_workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)

    assert_not_equal legacy.id, owner_workspace.id
    assert_equal "user-#{@owner.id}", owner_workspace.proxy_credential_id
    assert_equal "agent-#{@agent.id}", owner_workspace.proxy_workspace_id
    assert_not_equal legacy_manifest_token, owner_workspace.manifest_token
    assert_predicate legacy_access_token.reload, :revoked?
    assert_raises(ActiveRecord::RecordNotFound) do
      Collavre::AgentWorkspace.find_by_manifest_token!(agent_id: @agent.id, token: legacy_manifest_token)
    end
  end

  test "rotating tokens preserves manifest capability and revokes old callback token" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)
    gateway = workspace.agent_gateway
    agent = workspace.agent
    old_manifest = workspace.manifest_token
    old_callback = workspace.callback_token
    lock_order = []

    gateway.stub(:with_lock, ->(&block) { lock_order << :gateway; block.call }) do
      agent.stub(:with_lock, ->(&block) { lock_order << :agent; block.call }) do
        workspace.stub(:with_lock, ->(&block) { lock_order << :workspace; block.call }) do
          workspace.rotate_tokens!
        end
      end
    end

    assert_equal %i[gateway agent workspace], lock_order
    assert_equal old_manifest, workspace.manifest_token
    assert_not_equal old_callback, workspace.callback_token
    assert Doorkeeper::AccessToken.by_token(old_callback).revoked?
  end

  test "token rotation refuses a workspace after its gateway is deactivated" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)
    access_token_count = Doorkeeper::AccessToken.count

    @gateway.update!(active: false)

    error = assert_raises(ArgumentError) { workspace.rotate_tokens! }
    assert_equal "Agent gateway is inactive", error.message
    assert_equal access_token_count, Doorkeeper::AccessToken.count
  end

  test "token rotation refuses a workspace after its agent changes gateways" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)
    access_token_count = Doorkeeper::AccessToken.count
    replacement_gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Replacement proxy",
      base_url: "https://replacement.example.com",
      admin_key: "replacement-admin",
      completion_key: "replacement-completion",
      identity_secret: "r" * 32
    )
    @agent.update!(agent_gateway: replacement_gateway)

    assert_raises(ActiveRecord::RecordNotFound) { workspace.rotate_tokens! }
    assert_equal access_token_count, Doorkeeper::AccessToken.count
  end

  test "per-user credential axis is the Collavre user so one login covers every agent" do
    @gateway.update!(workspace_mode: :per_user)
    second_agent = Collavre::User.create!(
      name: "Second Workspace Agent",
      email: "workspace-agent-2@ai.local",
      password: SecureRandom.hex(24),
      system_prompt: "Help",
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/codex_local",
      created_by_id: @owner.id,
      agent_gateway: @gateway
    )

    first = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    second = Collavre::AgentWorkspace.resolve!(agent: second_agent, user: @owner)

    # Same worker (one engine login) but separate path workspaces.
    assert_equal first.proxy_credential_id, second.proxy_credential_id
    assert_equal "user-#{@owner.id}", first.proxy_credential_id
    assert_not_equal first.proxy_workspace_id, second.proxy_workspace_id
    assert_not_equal first.callback_token, second.callback_token
  end

  test "workspace axis rejects identifiers that are not one safe path segment" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)

    [ "../escape", "agent/12", "agent.12", "/agent-12", "" ].each do |candidate|
      workspace.proxy_workspace_id = candidate
      assert_not workspace.valid?, "expected #{candidate.inspect} to be rejected"
      assert_includes workspace.errors.attribute_names, :proxy_workspace_id
    end
  end

  test "resolution replaces a workspace minted under the legacy single-axis identity" do
    @gateway.update!(workspace_mode: :per_user)
    legacy = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    legacy.update_column(:proxy_credential_id, "agent-#{@agent.id}--user-#{@owner.id}")
    legacy_manifest_token = legacy.manifest_token
    legacy_access_token = Doorkeeper::AccessToken.by_token(legacy.callback_token)

    replacement = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)

    assert_not_equal legacy.id, replacement.id
    assert_equal "user-#{@owner.id}", replacement.proxy_credential_id
    assert_equal "agent-#{@agent.id}", replacement.proxy_workspace_id
    assert_predicate legacy_access_token.reload, :revoked?
    assert_raises(ActiveRecord::RecordNotFound) do
      Collavre::AgentWorkspace.find_by_manifest_token!(agent_id: @agent.id, token: legacy_manifest_token)
    end
  end

  test "migration maps each legacy identity onto both axes and back" do
    migration = SplitAgentWorkspaceIdentityAxes.new
    shared = Struct.new(:agent_id, :user_id).new(11, nil)
    per_user = Struct.new(:agent_id, :user_id).new(11, 7)

    assert_equal "agent-11", migration.send(:credential_id_for, shared)
    assert_equal "user-7", migration.send(:credential_id_for, per_user)
    assert_equal "agent-11", migration.send(:legacy_proxy_user_id_for, shared)
    assert_equal "agent-11--user-7", migration.send(:legacy_proxy_user_id_for, per_user)
  end
end
