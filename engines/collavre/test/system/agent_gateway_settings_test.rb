require_relative "../application_system_test_case"

class AgentGatewaySettingsTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "gateway-ui@example.com", password: SystemHelpers::PASSWORD,
                         name: "Gateway owner", email_verified_at: Time.current, locale: :en)
    @gateway = Collavre::AgentGateway.create!(owner: @user, name: "LongGateway" * 20,
                                            base_url: "https://#{'proxy' * 10}.example.com",
                                            admin_key: "secret-admin", completion_key: "secret-completion")
    sign_in_via_ui(@user)
  end

  test "gateway list and edit form fit mobile in both themes and preserve saved keys" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: true)
    visit collavre.agent_gateways_path
    assert_selector ".gateway-card h2", text: @gateway.name
    page.execute_script("document.body.classList.remove('dark-mode'); document.body.classList.add('light-mode')")
    assert_no_horizontal_overflow
    page.save_screenshot(Rails.root.join("tmp/screenshots/gateway-list-mobile.png"))
    page.execute_script("document.body.classList.remove('light-mode'); document.body.classList.add('dark-mode')")
    assert_no_horizontal_overflow
    click_link I18n.t("collavre.agent_gateways.edit")
    assert_selector ".gateway-form__section", count: 3
    page.execute_script("document.body.classList.remove('light-mode'); document.body.classList.add('dark-mode')")
    assert_no_horizontal_overflow
    page.save_screenshot(Rails.root.join("tmp/screenshots/gateway-form-mobile.png"))
    page.execute_script("document.body.classList.remove('dark-mode'); document.body.classList.add('light-mode')")
    assert_no_horizontal_overflow
    assert_equal "", find("input[name='agent_gateway[admin_key]']").value
    fill_in "agent_gateway_name", with: "Renamed gateway"
    click_button I18n.t("common.save")
    assert_selector ".gateway-card h2", text: "Renamed gateway"
    assert_equal "secret-admin", @gateway.reload.admin_key
    assert_equal "secret-completion", @gateway.completion_key
  end

  test "connection feedback stays within the selected card" do
    Collavre::AgentGateway.create!(owner: @user, name: "Second gateway",
                                  base_url: "https://second.example.com", admin_key: "second-secret")
    visit collavre.agent_gateways_path
    page.execute_script <<~JS
      window.fetch = async () => ({ json: async () => ({ok: true, engines: ['codex']}) });
    JS
    within(".gateway-card", text: "Second gateway") do
      click_button I18n.t("collavre.agent_gateways.check")
      assert_selector "[role='status']", text: "codex"
      assert_button I18n.t("collavre.agent_gateways.check"), disabled: false
    end
    within(".gateway-card", text: @gateway.name) do
      assert_no_selector "[role='status']", text: "codex"
    end
  end

  private

  def assert_no_horizontal_overflow
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    assert page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('.gateway-card, .gateway-form__section')).every(
        element => element.scrollWidth <= element.clientWidth
      )
    JS
  end
end
