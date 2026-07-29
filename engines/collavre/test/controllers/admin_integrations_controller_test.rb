require "test_helper"

class AdminIntegrationsControllerTest < ActionDispatch::IntegrationTest
  Registry = Collavre::IntegrationSettings::Registry
  Resolver = Collavre::IntegrationSettings::Resolver
  IntegrationSetting = Collavre::IntegrationSetting

  setup do
    @admin = users(:one)
    @user  = users(:two)

    # Reset registry for hermetic tests, but snapshot boot-time
    # registrations (e.g. Slack engine) so other tests in the same
    # process don't lose their key definitions.
    @registry_snapshot = Registry.instance.instance_variable_get(:@definitions).dup
    Registry.instance.instance_variable_set(:@definitions, {})
    Registry.instance.register(
      :slack_client_secret,
      category: "slack",
      sensitive: true,
      requires_restart: true,
      env_var: "SLACK_CLIENT_SECRET",
      default: nil
    )
    Registry.instance.register(
      :slack_client_id,
      category: "slack",
      sensitive: false,
      requires_restart: false,
      env_var: "SLACK_CLIENT_ID",
      default: nil
    )

    Rails.cache.clear
    IntegrationSetting.delete_all
  end

  teardown do
    Registry.instance.instance_variable_set(:@definitions, @registry_snapshot || {})
    ENV.delete("SLACK_CLIENT_ID")
    ENV.delete("SLACK_CLIENT_SECRET")
    Rails.cache.clear
  end

  # ---------- auth ----------

  test "non-admin user gets 404" do
    sign_in_as(@user, password: "password")
    get collavre.admin_integrations_path
    assert_response :not_found
  end

  test "admin user gets index 200" do
    sign_in_as(@admin, password: "password")
    get collavre.admin_integrations_path
    assert_response :success
  end

  test "index masks sensitive inputs without using password fields" do
    sign_in_as(@admin, password: "password")

    get collavre.admin_integrations_path

    assert_select "input[type='text'][name='integration_setting[slack_client_secret]'].masked-secret-field[autocomplete='off'][spellcheck='false']"
    assert_select "input[type='password'][name='integration_setting[slack_client_secret]']", count: 0
    assert_select "input[type='text'][name='integration_setting[slack_client_id]']:not(.masked-secret-field)"
  end

  # ---------- index display ----------

  test "index masks sensitive values" do
    IntegrationSetting.create!(
      key: "slack_client_secret",
      value: "supersecretplaintext12345",
      category: "slack"
    )
    sign_in_as(@admin, password: "password")

    get collavre.admin_integrations_path

    assert_response :success
    assert_not_includes response.body, "supersecretplaintext12345",
      "Plaintext value of a sensitive key must not appear in the HTML"
  end

  test "index renders empty state when registry is empty" do
    Registry.instance.instance_variable_set(:@definitions, {})
    sign_in_as(@admin, password: "password")

    get collavre.admin_integrations_path

    assert_response :success
    assert_includes response.body, I18n.t("collavre.admin.integrations.empty_state")
  end

  # ---------- bulk_update ----------

  test "bulk_update upserts non-blank values" do
    sign_in_as(@admin, password: "password")

    patch collavre.bulk_update_admin_integrations_path, params: {
      integration_setting: {
        slack_client_id: "client-id-from-form",
        slack_client_secret: ""
      }
    }

    assert_redirected_to collavre.admin_integrations_path

    row = IntegrationSetting.find_by(key: "slack_client_id")
    assert_not_nil row
    assert_equal "client-id-from-form", row.value
    assert_equal "slack", row.category

    # blank input was skipped — no row created
    assert_nil IntegrationSetting.find_by(key: "slack_client_secret")
  end

  test "bulk_update flashes restart_required when a restart key changed" do
    sign_in_as(@admin, password: "password")

    patch collavre.bulk_update_admin_integrations_path, params: {
      integration_setting: { slack_client_secret: "new-secret" }
    }

    assert_redirected_to collavre.admin_integrations_path
    follow_redirect!
    assert_match I18n.t("collavre.admin.integrations.flash.restart_required"), response.body
  end

  test "bulk_update does not flash restart_required when only non-restart keys change" do
    sign_in_as(@admin, password: "password")

    patch collavre.bulk_update_admin_integrations_path, params: {
      integration_setting: { slack_client_id: "id-only" }
    }

    assert_redirected_to collavre.admin_integrations_path
    assert_nil flash[:warning]
  end

  # ---------- reset ----------

  test "reset deletes the DB row, resolver falls back to ENV" do
    IntegrationSetting.create!(
      key: "slack_client_id", value: "db-val", category: "slack"
    )
    ENV["SLACK_CLIENT_ID"] = "env-val"
    Rails.cache.clear

    sign_in_as(@admin, password: "password")
    delete collavre.reset_admin_integration_path(key: "slack_client_id")

    assert_redirected_to collavre.admin_integrations_path
    assert_nil IntegrationSetting.find_by(key: "slack_client_id")
    Rails.cache.clear
    assert_equal "env-val", Resolver.get(:slack_client_id)
  end

  test "reset on unknown key returns 404" do
    sign_in_as(@admin, password: "password")
    delete collavre.reset_admin_integration_path(key: "no_such_key")
    assert_response :not_found
  end

  test "reset on a key hidden from the admin UI returns 404 and keeps the DB row" do
    Registry.instance.register(
      :hidden_resettable_key,
      category: "misc",
      sensitive: true,
      requires_restart: false,
      env_var: "HIDDEN_RESETTABLE_KEY",
      admin_visible: false
    )
    IntegrationSetting.create!(
      key: "hidden_resettable_key", value: "db-val", category: "misc"
    )
    sign_in_as(@admin, password: "password")

    delete collavre.reset_admin_integration_path(key: "hidden_resettable_key")

    assert_response :not_found
    assert_not_nil IntegrationSetting.find_by(key: "hidden_resettable_key"),
      "A crafted DELETE must not reset a key hidden from the admin UI"
  end

  # ---------- admin_visible / input_type ----------

  test "index hides keys with admin_visible: false" do
    Registry.instance.register(
      :hidden_key,
      category: "misc",
      sensitive: true,
      requires_restart: false,
      env_var: "HIDDEN_KEY",
      admin_visible: false
    )
    sign_in_as(@admin, password: "password")

    get collavre.admin_integrations_path

    assert_response :success
    assert_not_includes response.body, "hidden_key",
      "Keys with admin_visible: false must not appear in the admin UI"
  end

  test "index hides category whose keys are all admin_visible: false" do
    Registry.instance.instance_variable_set(:@definitions, {})
    Registry.instance.register(
      :hidden_only_key,
      category: "hidden_cat",
      sensitive: false,
      requires_restart: false,
      admin_visible: false
    )
    sign_in_as(@admin, password: "password")

    get collavre.admin_integrations_path

    assert_response :success
    assert_not_includes response.body, "hidden_cat"
  end

  test "index renders textarea for input_type: :textarea keys" do
    Registry.instance.register(
      :json_blob_key,
      category: "misc",
      sensitive: true,
      requires_restart: false,
      env_var: "JSON_BLOB_KEY",
      input_type: :textarea
    )
    sign_in_as(@admin, password: "password")

    get collavre.admin_integrations_path

    assert_response :success
    assert_match %r{<textarea[^>]*name="integration_setting\[json_blob_key\]"}, response.body
  end

  test "bulk_update ignores keys with admin_visible: false" do
    Registry.instance.register(
      :hidden_writable_key,
      category: "misc",
      sensitive: true,
      requires_restart: false,
      env_var: "HIDDEN_WRITABLE_KEY",
      admin_visible: false
    )
    sign_in_as(@admin, password: "password")

    patch collavre.bulk_update_admin_integrations_path, params: {
      integration_setting: { hidden_writable_key: "/tmp/injected" }
    }

    assert_redirected_to collavre.admin_integrations_path
    assert_nil IntegrationSetting.find_by(key: "hidden_writable_key"),
      "A crafted POST must not write a key hidden from the admin UI"
  end

  test "bulk_update saves multiline textarea value verbatim" do
    Registry.instance.register(
      :json_blob_key,
      category: "misc",
      sensitive: true,
      requires_restart: false,
      env_var: "JSON_BLOB_KEY",
      input_type: :textarea
    )
    sign_in_as(@admin, password: "password")

    multiline = %({\n  "type": "service_account",\n  "project_id": "demo"\n})
    patch collavre.bulk_update_admin_integrations_path, params: {
      integration_setting: { json_blob_key: multiline }
    }

    row = IntegrationSetting.find_by(key: "json_blob_key")
    assert_not_nil row
    assert_equal multiline, row.value
  end
end
