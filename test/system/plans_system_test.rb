require "application_system_test_case"

class PlansSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "plans-user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Planner",
      email_verified_at: Time.current,
      notifications_enabled: false,
      )

    resize_window_to
    sign_in_via_ui(@user)
  end

  test "user can create a plan and see it on the timeline" do
    find_all(".plans-menu-btn").first.click

    within "#plans-list-area" do
      fill_in "plan_name", with: "Launch Plan"
      fill_in "plan_target_date", with: Date.current
      click_button I18n.t("plans.add_plan")
    end

    within "#plans-list-area" do
      assert_selector ".plan-label", text: /Launch Plan/, wait: 5
    end
  end

  test "user can delete a plan" do
    find_all(".plans-menu-btn").first.click

    within "#plans-list-area" do
      fill_in "plan_name", with: "Plan to be deleted"
      fill_in "plan_target_date", with: Date.current
      click_button I18n.t("plans.add_plan")
    end

    within "#plans-list-area" do
      assert_selector ".plan-label", text: /Plan to be deleted/, wait: 5
      find(".plan-label", text: /Plan to be deleted/).find(:xpath, "..").find(".delete-plan-btn").click
    end

    accept_alert

    within "#plans-list-area" do
      assert_no_selector ".plan-label", text: /Plan to be deleted/, wait: 5
    end
  end
end
