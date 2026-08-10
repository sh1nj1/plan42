require "test_helper"

class DesktopSetupControllerTest < ActionDispatch::IntegrationTest
  test "visitor can review every desktop setup mockup step in English" do
    %w[account install adapters ready].each do |step|
      get collavre.desktop_setup_path(step: step, locale: :en)

      assert_response :success
      assert_includes response.body, I18n.t("collavre.desktop_setup.preview", locale: :en)
      assert_includes response.body, I18n.t("collavre.desktop_setup.steps.#{step}", locale: :en)
    end
  end

  test "visitor can review the Korean CLI privacy guidance" do
    get collavre.desktop_setup_path(step: :adapters, locale: :ko)

    assert_response :success
    assert_includes response.body, I18n.t("collavre.desktop_setup.adapters.notice", locale: :ko)
    assert_includes response.body, I18n.t("collavre.desktop_setup.adapters.codex.body", locale: :ko)
  end

  test "visitor can review the administrator account form without an existing account" do
    get collavre.desktop_setup_path

    assert_response :success
    assert_select "form.desktop-setup__account-form"
    assert_select "input#desktop-setup-admin-name[name='admin[name]'][autocomplete='name']"
    assert_select "input#desktop-setup-admin-email[name='admin[email]'][type='email']"
    assert_select "input#desktop-setup-admin-password[type='password'][autocomplete='new-password']"
    assert_select "input#desktop-setup-admin-password-confirmation[type='password'][autocomplete='new-password']"
  end

  test "unknown step falls back to the overview" do
    sign_in_as(users(:one), password: "password")

    get collavre.desktop_setup_path(step: "unsupported")

    assert_response :success
    assert_includes response.body, I18n.t("collavre.desktop_setup.account.title")
  end
end
