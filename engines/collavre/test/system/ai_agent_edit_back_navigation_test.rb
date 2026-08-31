require_relative "../application_system_test_case"

# Saving an AI agent used to push a new history entry and land on a fixed page,
# so the browser back button walked back into the edit form instead of the list
# the user opened it from.
class AiAgentEditBackNavigationTest < ApplicationSystemTestCase
  setup do
    @admin = User.create!(
      email: "ai-back-nav@example.com",
      password: SystemHelpers::PASSWORD,
      name: "AI Back Nav",
      email_verified_at: Time.current,
      notifications_enabled: false,
      system_admin: true
    )
    @agent = User.create!(
      email: "back-nav-bot@ai.local",
      password: SecureRandom.hex(36),
      name: "Back Nav Bot",
      system_prompt: "Be helpful",
      llm_vendor: "google",
      llm_model: "gemini-1.5-pro",
      email_verified_at: Time.current,
      created_by_id: @admin.id
    )

    resize_window_to
    sign_in_via_ui(@admin)
  end

  test "saving an ai agent returns to the user list and back does not reopen the form" do
    visit collavre.users_path
    click_link @agent.name
    assert_current_path collavre.edit_ai_user_path(@agent)

    click_button I18n.t("common.save")

    assert_current_path collavre.users_path
    page.go_back
    assert_current_path collavre.users_path
  end
end
