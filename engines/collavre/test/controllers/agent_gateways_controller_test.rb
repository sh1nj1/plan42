require "test_helper"

class AgentGatewaysControllerTest < ActionDispatch::IntegrationTest
  FakeProxyClient = Struct.new(:result, :error, keyword_init: true) do
    def engines
      raise error if error

      result
    end
  end

  setup do
    @owner = users(:two)
    @other = users(:three)
    @gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "My proxy",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
  end

  test "owner manages gateways from user settings" do
    sign_in_as(@owner, password: "password")

    get collavre.agent_gateways_path
    assert_response :success
    assert_includes response.body, "My proxy"

    post collavre.agent_gateways_path, params: {
      agent_gateway: {
        name: "Second proxy",
        base_url: "https://second.example.com",
        admin_key: "admin-2",
        completion_key: "completion-2",
        identity_secret: "s" * 32,
        workspace_mode: "per_user",
        tenant_id: "collavre",
        active: "1"
      }
    }
    assert_redirected_to collavre.agent_gateways_path
    assert @owner.owned_agent_gateways.exists?(name: "Second proxy")
  end

  test "gateway form explains the owner-specific endpoint policy" do
    sign_in_as(@owner, password: "password")
    get collavre.new_agent_gateway_path
    assert_response :success
    assert_includes response.body, I18n.t("collavre.agent_gateways.base_url_help")

    sign_out
    sign_in_as(users(:one), password: "password")
    get collavre.new_agent_gateway_path
    assert_response :success
    assert_includes response.body, I18n.t("collavre.agent_gateways.base_url_help_admin")
  end

  test "user cannot edit another user's gateway" do
    sign_in_as(@other, password: "password")
    get collavre.edit_agent_gateway_path(@gateway)
    assert_response :not_found
  end

  test "blank secret fields retain encrypted values on update" do
    sign_in_as(@owner, password: "password")
    patch collavre.agent_gateway_path(@gateway), params: {
      agent_gateway: {
        name: "Renamed",
        base_url: @gateway.base_url,
        admin_key: "",
        completion_key: "",
        identity_secret: "",
        tenant_id: "collavre",
        workspace_mode: "shared",
        active: "1"
      }
    }

    assert_redirected_to collavre.agent_gateways_path
    assert_equal "admin", @gateway.reload.admin_key
    assert_equal "completion", @gateway.completion_key
  end

  test "owner cannot retarget a desktop-managed gateway from settings" do
    desktop_gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Desktop proxy",
      base_url: "http://127.0.0.1:34567",
      admin_key: "desktop-admin",
      completion_key: "desktop-completion",
      identity_secret: "d" * 32,
      desktop_managed: true
    )
    sign_in_as(@owner, password: "password")

    patch collavre.agent_gateway_path(desktop_gateway), params: {
      agent_gateway: {
        name: desktop_gateway.name,
        base_url: "http://127.0.0.1:45678",
        admin_key: "",
        completion_key: "",
        identity_secret: "",
        tenant_id: desktop_gateway.tenant_id,
        workspace_mode: desktop_gateway.workspace_mode,
        active: "1"
      }
    }

    assert_response :unprocessable_entity
    assert_equal "http://127.0.0.1:34567", desktop_gateway.reload.base_url
  end

  test "owner cannot replace desktop-managed credentials from settings" do
    desktop_gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Desktop proxy",
      base_url: "http://127.0.0.1:34567",
      admin_key: "desktop-admin",
      completion_key: "desktop-completion",
      identity_secret: "d" * 32,
      desktop_managed: true
    )
    sign_in_as(@owner, password: "password")

    patch collavre.agent_gateway_path(desktop_gateway), params: {
      agent_gateway: {
        name: desktop_gateway.name,
        base_url: desktop_gateway.base_url,
        admin_key: "replacement-admin",
        completion_key: "replacement-completion",
        identity_secret: "r" * 32,
        tenant_id: desktop_gateway.tenant_id,
        workspace_mode: desktop_gateway.workspace_mode,
        active: "1"
      }
    }

    assert_response :unprocessable_entity
    desktop_gateway.reload
    assert_equal "desktop-admin", desktop_gateway.admin_key
    assert_equal "desktop-completion", desktop_gateway.completion_key
    assert_equal "d" * 32, desktop_gateway.identity_secret
  end

  test "owner cannot switch a desktop-managed gateway to per-user mode from settings" do
    desktop_gateway = Collavre::AgentGateway.create!(
      owner: @owner,
      name: "Desktop proxy",
      base_url: "http://127.0.0.1:34567",
      admin_key: "desktop-admin",
      completion_key: "desktop-completion",
      identity_secret: "d" * 32,
      desktop_managed: true
    )
    sign_in_as(@owner, password: "password")

    patch collavre.agent_gateway_path(desktop_gateway), params: {
      agent_gateway: {
        name: desktop_gateway.name,
        base_url: desktop_gateway.base_url,
        admin_key: "",
        completion_key: "",
        identity_secret: "",
        tenant_id: desktop_gateway.tenant_id,
        workspace_mode: "per_user",
        active: "1"
      }
    }

    assert_response :unprocessable_entity
    assert_predicate desktop_gateway.reload, :shared?
  end

  test "connection check uses completion key as mapped user key" do
    sign_in_as(@owner, password: "password")
    arguments = []
    client = FakeProxyClient.new(result: { "data" => [ { "engine" => "codex" } ] })

    Collavre::CliProxy::Client.stub(:new, ->(**kwargs) { arguments << kwargs; client }) do
      post collavre.check_agent_gateway_path(@gateway)
    end

    assert_response :success
    assert_equal true, response.parsed_body.fetch("identity_verified")
    assert_equal "completion_key", response.parsed_body.fetch("identity")
    assert_equal [ "codex" ], response.parsed_body.fetch("engines")
    assert_equal "completion", arguments.fetch(0).fetch(:user_key)
    assert_nil arguments.fetch(0)[:workspace]
  end

  test "connection check retries user identity error with an existing shared workspace" do
    workspace = create_shared_workspace
    sign_in_as(@owner, password: "password")
    arguments = []
    clients = [
      FakeProxyClient.new(
        error: Collavre::CliProxy::Client::Error.new(
          "A mapped user API key or valid signed user identity is required",
          code: "user_identity_required"
        )
      ),
      FakeProxyClient.new(result: { "data" => [ { "engine" => "claude" } ] })
    ]

    Collavre::CliProxy::Client.stub(:new, ->(**kwargs) { arguments << kwargs; clients.shift }) do
      post collavre.check_agent_gateway_path(@gateway)
    end

    assert_response :success
    assert_equal "workspace", response.parsed_body.fetch("identity")
    assert_equal [ "claude" ], response.parsed_body.fetch("engines")
    assert_equal "completion", arguments.fetch(0).fetch(:user_key)
    assert_equal workspace, arguments.fetch(1).fetch(:workspace)
    assert_nil arguments.fetch(1)[:user_key]
  end

  test "connection check uses an existing workspace directly when completion key is absent" do
    workspace = create_shared_workspace
    @gateway.update_column(:completion_key, "")
    sign_in_as(@owner, password: "password")
    arguments = []
    client = FakeProxyClient.new(result: { "data" => [ { "engine" => "claude" } ] })

    Collavre::CliProxy::Client.stub(:new, ->(**kwargs) { arguments << kwargs; client }) do
      post collavre.check_agent_gateway_path(@gateway)
    end

    assert_response :success
    assert_equal "workspace", response.parsed_body.fetch("identity")
    assert_equal [ "claude" ], response.parsed_body.fetch("engines")
    assert_equal 1, arguments.size
    assert_equal workspace, arguments.fetch(0).fetch(:workspace)
    assert_nil arguments.fetch(0)[:user_key]
  end

  test "connection check reports unverified identity without a completion key or workspace" do
    @gateway.update_column(:completion_key, "")
    sign_in_as(@owner, password: "password")
    arguments = []
    client = FakeProxyClient.new(result: { "data" => [ { "engine" => "codex" } ] })

    Collavre::CliProxy::Client.stub(:new, ->(**kwargs) { arguments << kwargs; client }) do
      post collavre.check_agent_gateway_path(@gateway)
    end

    assert_response :success
    assert_equal true, response.parsed_body.fetch("ok")
    assert_equal false, response.parsed_body.fetch("identity_verified")
    assert_equal [ "codex" ], response.parsed_body.fetch("engines")
    assert_equal 1, arguments.size
    assert_nil arguments.fetch(0)[:user_key]
    assert_nil arguments.fetch(0)[:workspace]
  end

  test "connection check distinguishes admin success when no identity can be verified" do
    sign_in_as(@owner, password: "password")
    client = FakeProxyClient.new(
      error: Collavre::CliProxy::Client::Error.new(
        "A mapped user API key or valid signed user identity is required",
        code: "user_identity_required"
      )
    )

    Collavre::CliProxy::Client.stub(:new, ->(**) { client }) do
      post collavre.check_agent_gateway_path(@gateway)
    end

    assert_response :success
    assert_equal true, response.parsed_body.fetch("ok")
    assert_equal false, response.parsed_body.fetch("identity_verified")
    assert_equal I18n.t("collavre.agent_gateways.identity_unverified"), response.parsed_body.fetch("warning")
  end

  test "per-user connection check only falls back to the current user's workspace" do
    @gateway.update!(workspace_mode: :per_user, identity_secret: "i" * 32)
    agent = create_agent
    other_workspace = create_workspace(agent: agent, user: @other, suffix: "other")
    owner_workspace = create_workspace(agent: agent, user: @owner, suffix: "owner")
    sign_in_as(@owner, password: "password")
    arguments = []
    clients = [
      FakeProxyClient.new(
        error: Collavre::CliProxy::Client::Error.new("Identity required", code: "user_identity_required")
      ),
      FakeProxyClient.new(result: { "data" => [] })
    ]

    Collavre::CliProxy::Client.stub(:new, ->(**kwargs) { arguments << kwargs; clients.shift }) do
      post collavre.check_agent_gateway_path(@gateway)
    end

    assert_response :success
    assert_equal owner_workspace, arguments.fetch(1).fetch(:workspace)
    assert_not_equal other_workspace, arguments.fetch(1).fetch(:workspace)
  end

  private

  def create_shared_workspace
    agent = create_agent
    create_workspace(agent: agent, user: nil, suffix: "shared")
  end

  def create_agent
    Collavre::User.create!(
      name: "Gateway check agent",
      email: "gateway-check-agent-#{SecureRandom.hex(4)}@ai.local",
      password: SecureRandom.hex(24),
      system_prompt: "Help",
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/codex_local",
      created_by_id: @owner.id,
      agent_gateway: @gateway
    )
  end

  def create_workspace(agent:, user:, suffix:)
    Collavre::AgentWorkspace.create!(
      agent: agent,
      user: user,
      agent_gateway: @gateway,
      proxy_credential_id: "agent-#{agent.id}-#{suffix}",
      proxy_workspace_id: "agent-#{agent.id}-#{suffix}",
      manifest_token: SecureRandom.urlsafe_base64(32),
      callback_token: SecureRandom.hex(32)
    )
  end
end
