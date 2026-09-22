require_relative "../application_system_test_case"

class LlmUsagesSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "usage-ui@example.com", password: SystemHelpers::PASSWORD,
                        name: "Usage owner", email_verified_at: Time.current, locale: :en)
    Collavre::LlmUsage.create!(event_key: "ui", execution_id: "ui", vendor: "openai", model: "example-model",
      owner_id: @user.id, requester_id: @user.id, requester_ids: [ @user.id ], requester_kind: "human",
      occurred_at: Time.current, input_tokens: 100, output_tokens: 20, cache_read_tokens: 70)
    Collavre::ToolUsage.create!(event_key: "ui-tool", execution_id: "ui", source: "internal", tool_name: "creative_retrieval_service",
      owner_id: @user.id, requester_id: @user.id, requester_ids: [ @user.id ], requester_kind: "human",
      occurred_at: Time.current, duration_ms: 42)
    sign_in_via_ui(@user)
  end

  test "profile opens usage with working grouping and filters on mobile" do
    visit collavre.user_path(@user)
    click_link I18n.t("collavre.llm_usages.title")
    assert_selector ".usage-report > .usage-report__table tbody tr", count: 1
    select "Monthly", from: "period"
    select "Requester", from: "group"
    select "Usage owner", from: "requester_id"
    click_button "Apply"
    assert_selector "tbody td", text: "Usage owner"
    assert_selector "tbody td", text: "100"
    assert_selector "tbody small", text: "1 unreported"
    assert_selector ".usage-report__tools td", text: "creative_retrieval_service"
    assert_selector ".usage-report__tools td", text: "42 ms"
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: true)
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
    page.save_screenshot(Rails.root.join("tmp", "llm-usages-mobile.png"))
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
