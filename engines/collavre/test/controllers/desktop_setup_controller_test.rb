require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260810100000_add_desktop_managed_to_agent_gateways")
require Rails.root.join("engines/collavre/db/migrate/20260810100001_add_desktop_preset_adapter_to_users")

class DesktopSetupControllerTest < ActionDispatch::IntegrationTest
  setup do
    @desktop_proxy_setup = Rails.application.config.x.desktop_proxy_setup
    Rails.application.config.x.desktop_proxy_setup = true
  end

  teardown do
    Rails.application.config.x.desktop_proxy_setup = @desktop_proxy_setup
  end

  test "first desktop account is created locally and becomes the administrator" do
    Collavre::User.where(system_admin: true).update_all(system_admin: false)

    post collavre.desktop_setup_account_path, params: {
      admin: { name: "Desktop owner", email: "owner@desktop.test", password: "secure-password", password_confirmation: "secure-password" }
    }

    owner = Collavre::User.find_by!(email: "owner@desktop.test")
    assert owner.system_admin?
    assert owner.email_verified?
    assert_redirected_to collavre.desktop_setup_path(step: :install)
    assert_not_nil cookies[:session_id]
  end

  test "signed native registration creates the loopback gateway and detected presets" do
    owner = users(:one)
    sign_in_as(owner, password: "password")

    post collavre.desktop_setup_registration_token_path
    assert_response :success
    token = response.parsed_body.fetch("token")

    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: token,
      proxy_port: 34_567,
      admin_key: "admin-key",
      completion_key: "completion-key",
      identity_secret: "i" * 48,
      adapters: %w[claude codex unsupported]
    }, as: :json

    assert_response :created
    gateway = owner.owned_agent_gateways.find_by!(name: Collavre::DesktopSetupController::DESKTOP_GATEWAY_NAME)
    assert_equal "http://127.0.0.1:34567", gateway.base_url
    assert_equal "admin-key", gateway.admin_key
    assert_equal "completion-key", gateway.completion_key
    assert_equal %w[paperclip/claude_local paperclip/codex_local], owner.created_ai_users.order(:llm_model).pluck(:llm_model)
    assert_equal 2, Collavre::Contact.where(user: owner, contact_user: owner.created_ai_users).count
    assert_equal %w[claude codex], response.parsed_body.fetch("adapters")
  end

  test "repair preserves an existing desktop preset's custom attributes" do
    owner = users(:one)
    sign_in_as(owner, password: "password")

    post collavre.desktop_setup_registration_token_path
    token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: token,
      proxy_port: 34_567,
      admin_key: "admin-key",
      completion_key: "completion-key",
      identity_secret: "i" * 48,
      adapters: [ "claude" ]
    }, as: :json

    existing = owner.created_ai_users.find_by!(email: "collavre-desktop-claude-code@ai.local")
    existing.update!(name: "Customized Claude", llm_model: "custom/model", searchable: true, tools: [ "web_search" ])

    post collavre.desktop_setup_registration_token_path
    token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: token,
      proxy_port: 34_567,
      admin_key: "new-admin-key",
      completion_key: "new-completion-key",
      identity_secret: "i" * 48,
      adapters: [ "claude" ]
    }, as: :json

    assert_response :created
    existing.reload
    assert_equal "Customized Claude", existing.name
    assert_equal "custom/model", existing.llm_model
    assert_predicate existing, :searchable?
    assert_equal [ "web_search" ], existing.tools
    assert Collavre::Contact.exists?(user: owner, contact_user: existing)
  end

  test "registration does not adopt an ordinary agent with a desktop preset email" do
    owner = users(:one)
    ordinary_agent = Collavre::User.create!(
      name: "Ordinary Claude",
      email: "collavre-desktop-claude-code@ai.local",
      password: "secure-password",
      email_verified_at: Time.current,
      llm_vendor: "anthropic",
      llm_model: "claude-sonnet-4-5",
      created_by_id: owner.id,
      searchable: true,
      tools: [ "web_search" ]
    )
    sign_in_as(owner, password: "password")

    post collavre.desktop_setup_registration_token_path
    token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: token,
      proxy_port: 34_567,
      admin_key: "admin-key",
      completion_key: "completion-key",
      identity_secret: "i" * 48,
      adapters: [ "claude" ]
    }, as: :json

    assert_response :created
    ordinary_agent.reload
    assert_equal "anthropic", ordinary_agent.llm_vendor
    assert_equal "claude-sonnet-4-5", ordinary_agent.llm_model
    assert_predicate ordinary_agent, :searchable?
    preset = owner.created_ai_users.find_by!(desktop_preset_adapter: "claude")
    assert_equal "collavre-desktop-claude-code+desktop-#{preset.agent_gateway_id}@ai.local", preset.email
    assert_equal "cli_proxy", preset.llm_vendor
    assert_equal "paperclip/claude_local", preset.llm_model
  end

  test "registration preserves an owner's ordinary gateway with the desktop gateway name" do
    owner = users(:one)
    ordinary_gateway = Collavre::AgentGateway.create!(
      owner: owner,
      name: Collavre::DesktopSetupController::DESKTOP_GATEWAY_NAME,
      base_url: "https://ordinary.example.test",
      admin_key: "ordinary-admin-key",
      completion_key: "ordinary-completion-key",
      identity_secret: "o" * 48,
      tenant_id: "ordinary-gateway"
    )
    sign_in_as(owner, password: "password")

    post collavre.desktop_setup_registration_token_path
    token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: token,
      proxy_port: 34_567,
      admin_key: "desktop-admin-key",
      completion_key: "desktop-completion-key",
      identity_secret: "i" * 48,
      adapters: []
    }, as: :json

    assert_response :created
    desktop_gateway = Collavre::AgentGateway.find_by!(desktop_managed: true)
    assert_equal "#{Collavre::DesktopSetupController::DESKTOP_GATEWAY_NAME} (2)", desktop_gateway.name
    assert_equal owner, desktop_gateway.owner
    assert_equal "http://127.0.0.1:34567", desktop_gateway.base_url
    ordinary_gateway.reload
    assert_equal "https://ordinary.example.test", ordinary_gateway.base_url
    assert_not_predicate ordinary_gateway, :desktop_managed?
  end

  test "recovery updates the original desktop gateway when another administrator is signed in" do
    owner = users(:one)
    unrelated_gateway = Collavre::AgentGateway.create!(
      owner: users(:two),
      name: Collavre::DesktopSetupController::DESKTOP_GATEWAY_NAME,
      base_url: "https://unrelated.example.test",
      admin_key: "unrelated-admin-key",
      completion_key: "unrelated-completion-key",
      identity_secret: "u" * 48,
      tenant_id: "unrelated-gateway"
    )
    sign_in_as(owner, password: "password")

    post collavre.desktop_setup_registration_token_path
    owner_token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: owner_token,
      proxy_port: 34_567,
      admin_key: "owner-admin-key",
      completion_key: "owner-completion-key",
      identity_secret: "i" * 48,
      adapters: [ "claude" ]
    }, as: :json

    gateway = owner.owned_agent_gateways.find_by!(name: Collavre::DesktopSetupController::DESKTOP_GATEWAY_NAME)
    users(:two).update!(system_admin: true)
    sign_in_as(users(:two), password: "password")

    post collavre.desktop_setup_registration_token_path
    recovery_token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: recovery_token,
      proxy_port: 45_678,
      admin_key: "recovery-admin-key",
      completion_key: "recovery-completion-key",
      identity_secret: "s" * 48,
      adapters: [ "claude" ]
    }, as: :json

    assert_response :created
    assert_equal 1, Collavre::AgentGateway.where(desktop_managed: true).count
    gateway.reload
    assert_equal owner, gateway.owner
    assert_equal "http://127.0.0.1:45678", gateway.base_url
    assert_equal "recovery-admin-key", gateway.admin_key
    assert_equal [ "collavre-desktop-claude-code@ai.local" ], owner.created_ai_users.pluck(:email)
    assert_empty users(:two).created_ai_users.where(email: "collavre-desktop-claude-code@ai.local")
    unrelated_gateway.reload
    assert_equal "https://unrelated.example.test", unrelated_gateway.base_url
    assert_equal "unrelated-admin-key", unrelated_gateway.admin_key
    assert_not_predicate unrelated_gateway, :desktop_managed?
  end

  test "recovery keeps the desktop gateway usable after its owner loses administrator rights" do
    owner = users(:one)
    sign_in_as(owner, password: "password")

    post collavre.desktop_setup_registration_token_path
    owner_token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: owner_token,
      proxy_port: 34_567,
      admin_key: "owner-admin-key",
      completion_key: "owner-completion-key",
      identity_secret: "i" * 48,
      adapters: [ "claude" ]
    }, as: :json
    assert_response :created

    gateway = Collavre::AgentGateway.find_by!(desktop_managed: true)
    users(:two).update!(system_admin: true)
    owner.update!(system_admin: false)
    sign_in_as(users(:two), password: "password")

    post collavre.desktop_setup_registration_token_path
    recovery_token = response.parsed_body.fetch("token")
    post collavre.desktop_setup_register_gateway_path, params: {
      registration_token: recovery_token,
      proxy_port: 45_678,
      admin_key: "recovery-admin-key",
      completion_key: "recovery-completion-key",
      identity_secret: "s" * 48,
      adapters: [ "claude" ]
    }, as: :json

    assert_response :created
    gateway.reload
    assert_equal owner, gateway.owner
    assert_equal "http://127.0.0.1:45678", gateway.base_url
    assert_predicate gateway, :desktop_loopback?
    assert_nil Collavre::CliProxy::Client.new(gateway: gateway).instance_variable_get(:@http_client).instance_variable_get(:@endpoint_policy)
    assert_equal [ "collavre-desktop-claude-code@ai.local" ], owner.created_ai_users.pluck(:email)
  end

  test "migration marks the unambiguous legacy desktop gateway" do
    users(:one).update!(system_admin: true)
    legacy_gateway = Collavre::AgentGateway.create!(
      owner: users(:one),
      name: Collavre::DesktopSetupController::DESKTOP_GATEWAY_NAME,
      base_url: "http://127.0.0.1:35000",
      admin_key: "legacy-admin-key",
      completion_key: "legacy-completion-key",
      identity_secret: "l" * 48,
      tenant_id: "collavre-desktop"
    )
    Collavre::User.create!(
      name: "Claude Code",
      email: "collavre-desktop-claude-code@ai.local",
      password: "secure-password",
      email_verified_at: Time.current,
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/claude_local",
      created_by_id: users(:one).id,
      agent_gateway: legacy_gateway,
      tools: []
    )

    AddDesktopManagedToAgentGateways.new.migrate(:up)

    assert_predicate legacy_gateway.reload, :desktop_managed?
  end

  test "migration does not mark an ordinary gateway that only uses the legacy tenant ID" do
    ordinary_gateway = Collavre::AgentGateway.create!(
      owner: users(:one),
      name: "Ordinary gateway",
      base_url: "http://127.0.0.1:35000",
      admin_key: "ordinary-admin-key",
      completion_key: "ordinary-completion-key",
      identity_secret: "o" * 48,
      tenant_id: "collavre-desktop"
    )

    AddDesktopManagedToAgentGateways.new.migrate(:up)

    assert_not_predicate ordinary_gateway.reload, :desktop_managed?
  end

  test "migration marks a renamed legacy desktop gateway and its preset" do
    users(:one).update!(system_admin: true)
    legacy_gateway = Collavre::AgentGateway.create!(
      owner: users(:one),
      name: "My renamed local proxy",
      base_url: "http://127.0.0.1:35000",
      admin_key: "legacy-admin-key",
      completion_key: "legacy-completion-key",
      identity_secret: "l" * 48,
      tenant_id: "collavre-desktop"
    )
    preset = Collavre::User.create!(
      name: "Claude Code",
      email: "collavre-desktop-claude-code@ai.local",
      password: "secure-password",
      email_verified_at: Time.current,
      llm_vendor: "cli_proxy",
      llm_model: "custom/model",
      created_by_id: users(:one).id,
      agent_gateway: legacy_gateway,
      tools: []
    )

    AddDesktopManagedToAgentGateways.new.migrate(:up)
    AddDesktopPresetAdapterToUsers.new.migrate(:up)

    assert_predicate legacy_gateway.reload, :desktop_managed?
    assert_equal "claude", preset.reload.desktop_preset_adapter
  end

  test "registration rejects a missing native grant" do
    post collavre.desktop_setup_register_gateway_path, params: { proxy_port: 34_567 }, as: :json

    assert_response :unprocessable_entity
  end

  test "native setup consent validation accepts only a current administrator grant" do
    owner = users(:one)
    sign_in_as(owner, password: "password")
    post collavre.desktop_setup_registration_token_path
    token = response.parsed_body.fetch("token")

    post collavre.desktop_setup_validate_registration_grant_path,
         params: { registration_token: token }, as: :json
    assert_response :no_content

    post collavre.desktop_setup_validate_registration_grant_path,
         params: { registration_token: "invalid" }, as: :json
    assert_response :unprocessable_entity
  end

  test "first administrator creation rejects non-loopback requests" do
    Collavre::User.where(system_admin: true).update_all(system_admin: false)

    post collavre.desktop_setup_account_path,
         params: { admin: { name: "Remote", email: "remote@desktop.test", password: "secure-password", password_confirmation: "secure-password" } },
         headers: { "REMOTE_ADDR" => "10.0.0.25" }

    assert_response :forbidden
    assert_nil Collavre::User.find_by(email: "remote@desktop.test")
  end

  test "first administrator creation is unavailable outside desktop mode" do
    Collavre::User.where(system_admin: true).update_all(system_admin: false)
    Rails.application.config.x.desktop_proxy_setup = false

    post collavre.desktop_setup_account_path, params: {
      admin: { name: "Web", email: "web@desktop.test", password: "secure-password", password_confirmation: "secure-password" }
    }

    assert_response :not_found
    assert_nil Collavre::User.find_by(email: "web@desktop.test")
  end

  test "a second local signup cannot become another first administrator" do
    post collavre.desktop_setup_account_path, params: {
      admin: { name: "Second", email: "second@desktop.test", password: "secure-password", password_confirmation: "secure-password" }
    }

    assert_redirected_to collavre.new_session_path
    assert_nil Collavre::User.find_by(email: "second@desktop.test")
    assert_equal 1, Collavre::User.where(system_admin: true).count
  end

  test "non-administrators cannot obtain a desktop registration token" do
    sign_in_as(users(:two), password: "password")

    post collavre.desktop_setup_registration_token_path

    assert_response :forbidden
  end

  test "registration tokens are limited to the local desktop webview" do
    sign_in_as(users(:one), password: "password")

    post collavre.desktop_setup_registration_token_path, headers: { "REMOTE_ADDR" => "10.0.0.25" }

    assert_response :forbidden
  end

  test "an existing administrator returns to incomplete setup after login" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current)
    get collavre.desktop_setup_path

    assert_redirected_to collavre.new_session_path
    post collavre.session_path, params: { email: owner.email, password: "password" }

    assert_redirected_to collavre.desktop_setup_path(step: :install)
  end

  test "an authenticated administrator resumes recovery at installation" do
    sign_in_as(users(:one), password: "password")

    get collavre.desktop_setup_path

    assert_response :success
    assert_select "[data-controller='desktop-proxy-setup']"
  end

  test "an authenticated non-administrator can switch to the owner during recovery" do
    sign_in_as(users(:two), password: "password")

    get collavre.desktop_setup_path(step: :install)

    assert_response :success
    assert_select "form[action='#{collavre.session_path}'] input[name='_method'][value='delete']"
    assert_select "a[href='#{collavre.new_session_path}']"
    assert_select "[data-controller='desktop-proxy-setup']", count: 0
  end

  test "switching accounts during recovery returns the administrator to installation" do
    owner = users(:one)
    owner.update!(email_verified_at: Time.current)
    sign_in_as(users(:two), password: "password")

    get collavre.desktop_setup_path(step: :install)
    delete collavre.session_path
    post collavre.session_path, params: { email: owner.email, password: "password" }

    assert_redirected_to collavre.desktop_setup_path(step: :install)
  end

  test "setup renders actual account controls and dynamic adapter statuses" do
    Collavre::User.where(system_admin: true).update_all(system_admin: false)
    get collavre.desktop_setup_path(step: :account, locale: :en)

    assert_response :success
    assert_select "form[action='#{collavre.desktop_setup_account_path}']"
    assert_select "input#desktop-setup-admin-password[type='password'][autocomplete='new-password']"

    get collavre.desktop_setup_path(step: :adapters, claude: 1, locale: :en)
    assert_response :success
    assert_includes response.body, I18n.t("collavre.desktop_setup.adapters.detected", locale: :en)
    assert_includes response.body, I18n.t("collavre.desktop_setup.adapters.not_detected", locale: :en)
  end
end
