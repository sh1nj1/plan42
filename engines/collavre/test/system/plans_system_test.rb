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
    Creative.create!(user: @user, description: "Launch Creative")

    find_all(".plans-menu-btn").first.click


    # Click input to open search popup
    find("#plan-select-creative-input").click

    fill_in "link-creative-search", with: "Launch Creative"
    find("#link-creative-results li", text: "Launch Creative", wait: 5).click

    within "#plans-list-area" do
      fill_in "plan-target-date", with: Date.current
      assert_selector "#add-plan-btn:not([disabled])", wait: 5
      click_button I18n.t("plans.add_plan")
    end

    begin
      assert_selector ".plan-label", text: /Launch Creative/, visible: :all, wait: 10
    rescue StandardError => e
      logs = page.driver.browser.manage.logs.get(:browser).map(&:message).join("\n")
      puts "BROWSER LOGS:\n#{logs}"
      raise e
    end
  end

  test "user can delete a plan" do
    creative = Creative.create!(user: @user, description: "Plan to be deleted")

    find_all(".plans-menu-btn").first.click

    # Click input to open search popup
    find("#plan-select-creative-input").click

    fill_in "link-creative-search", with: "Plan to be deleted"
    find("#link-creative-results li", text: "Plan to be deleted", wait: 5).click

    within "#plans-list-area" do
      fill_in "plan-target-date", with: Date.current
      assert_selector "#add-plan-btn:not([disabled])", wait: 5
      click_button I18n.t("plans.add_plan")
    end

    # Wait for the plan to appear on the timeline (use visible: :all since plan might be outside visible scroll area)
    begin
      assert_selector ".plan-label", text: /Plan to be deleted/, visible: :all, wait: 10
    rescue StandardError => e
      logs = page.driver.browser.manage.logs.get(:browser).map(&:message).join("\n")
      puts "BROWSER LOGS:\n#{logs}"
      Rails.logger.fatal "BROWSER LOGS:\n#{logs}"
      raise e
    end

    within "#plans-list-area" do
      # Find the plan bar and use JavaScript to click the delete button (more reliable)
      plan_bar = find(".plan-bar", text: /Plan to be deleted/, visible: :all)
      delete_btn = plan_bar.find(".delete-plan-btn", visible: :all)
      page.execute_script("arguments[0].click()", delete_btn)
    end

    accept_alert

    within "#plans-list-area" do
      assert_no_selector ".plan-label", text: /Plan to be deleted/, wait: 5
    end
  end
end
