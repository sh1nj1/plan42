require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260809000003_hash_agent_workspace_callback_tokens")

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
    assert_equal "agent-#{@agent.id}", first.proxy_user_id
    assert Doorkeeper::AccessToken.by_token(first.callback_token).accessible?
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

  test "per-user mode isolates users and preserves owner shared identity" do
    shared = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    shared_manifest_token = shared.manifest_token
    shared_callback_token = shared.callback_token
    shared_access_token = Doorkeeper::AccessToken.by_token(shared_callback_token)
    @gateway.update!(workspace_mode: :per_user)

    owner_workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @owner)
    other_workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: @other)

    assert_equal shared.id, owner_workspace.id
    assert_equal @owner, owner_workspace.user
    assert_equal "agent-#{@agent.id}", owner_workspace.proxy_user_id
    assert_equal shared_manifest_token, owner_workspace.manifest_token
    assert_not_equal shared_callback_token, owner_workspace.callback_token
    assert_predicate shared_access_token.reload, :revoked?
    owner_access_token = Doorkeeper::AccessToken.by_token(owner_workspace.callback_token)
    assert_equal @owner.id, owner_access_token.resource_owner_id
    assert_predicate owner_access_token, :accessible?
    assert_equal "agent-#{@agent.id}--user-#{@other.id}", other_workspace.proxy_user_id
    assert_not_equal owner_workspace.callback_token, other_workspace.callback_token
  end

  test "rotating tokens preserves manifest capability and revokes old callback token" do
    workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: nil)
    old_manifest = workspace.manifest_token
    old_callback = workspace.callback_token
    lock_calls = 0

    workspace.stub(:with_lock, ->(&block) { lock_calls += 1; block.call }) do
      workspace.rotate_tokens!
    end

    assert_equal 1, lock_calls
    assert_equal old_manifest, workspace.manifest_token
    assert_not_equal old_callback, workspace.callback_token
    assert Doorkeeper::AccessToken.by_token(old_callback).revoked?
  end
end
