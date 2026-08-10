require "test_helper"

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

  test "registration rejects a missing native grant" do
    post collavre.desktop_setup_register_gateway_path, params: { proxy_port: 34_567 }, as: :json

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
