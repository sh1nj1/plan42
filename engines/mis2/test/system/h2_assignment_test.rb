# System test for H2 Assignment management
# Uses main app context for full Rails stack

require_relative "../../../../test/application_system_test_case"

module Mis2
  class H2AssignmentTest < ApplicationSystemTestCase
    # Load H2 fixtures
    fixtures :users  # From main app

    setup do
      @user = users(:one)

      # Create H2 test data - fixtures don't work well across databases
      # so we create data directly
      @h2_org = Mis2::H2::Organization.find_or_create_by!(organization_idx: 1) do |org|
        org.organization_name = "Test Organization"
      end

      @h2_user = Mis2::H2::User.find_or_create_by!(user_idx: 1) do |u|
        u.name = "Test User"
        u.date_of_birth = "19900101"
        u.phone = "01012345678"
        u.organization_idx = 1
      end

      @h2_assignment = Mis2::H2::Assignment.find_or_create_by!(assignment_idx: 1) do |a|
        a.assignment_name = "Test Training Program"
      end

      @h2_assignment_user = Mis2::H2::AssignmentUser.find_or_create_by!(assignment_user_idx: 1) do |au|
        au.user = @h2_user
        au.assignment_record = @h2_assignment
        au.assignment_user_start = Date.current + 7.days
        au.assignment_user_end = Date.current + 14.days
        au.round = 1
        au.create_time = Time.current
      end
    end

    teardown do
      # Clean up H2 data
      Mis2::H2::AssignmentUser.delete_all
      Mis2::H2::Assignment.delete_all
      Mis2::H2::User.delete_all
      Mis2::H2::Organization.delete_all
    end

    test "search for H2 user and update assignment dates" do
      sign_in_system(@user)

      # Navigate to H2 assignments
      visit mis2.h2_assignments_path

      # Search for user
      fill_in "query", with: "Test User"
      click_button I18n.t("mis2.h2.assignments.index.search_button")

      # Verify user appears in results
      assert_text "Test User"
      assert_text "Test Organization"

      # Click select to edit assignments
      click_link I18n.t("mis2.h2.assignments.index.select_action")

      # Verify we're on the edit page
      assert_text I18n.t("mis2.h2.assignments.edit.title", name: "Test User")
      assert_text "Test Training Program"

      # Change the start date
      new_start = (Date.current + 10.days).strftime("%Y-%m-%d")
      new_end = (Date.current + 17.days).strftime("%Y-%m-%d")

      # Set date inputs using JavaScript for reliability
      execute_script("document.querySelector(\"input[name='start_date']\").value = '#{new_start}'")
      execute_script("document.querySelector(\"input[name='end_date']\").value = '#{new_end}'")
      execute_script("document.querySelector(\"input[name='start_date']\").dispatchEvent(new Event('input', { bubbles: true }))")
      execute_script("document.querySelector(\"input[name='end_date']\").dispatchEvent(new Event('input', { bubbles: true }))")

      # The update button should be enabled after changing dates
      update_button = find("button[type='submit'][form^='update_assignment']")
      assert_not update_button.disabled?

      # Accept the confirmation dialog and submit
      accept_confirm do
        update_button.click
      end

      # Verify success message
      assert_text I18n.t("mis2.h2.assignments.notices.update_success")

      # Verify the dates were updated in the database
      @h2_assignment_user.reload
      assert_equal Date.parse(new_start), @h2_assignment_user.assignment_user_start
      assert_equal Date.parse(new_end), @h2_assignment_user.assignment_user_end

      # Verify activity log was created
      activity_log = Mis2::ActivityLog.last
      assert_not_nil activity_log
      assert_equal "h2_training_update", activity_log.action
      assert_equal @user.id, activity_log.user_id
      assert_equal @user.name, activity_log.user_name
      assert_includes activity_log.message, "Test Training Program"
      assert_includes activity_log.message, "Test User"
    end

    test "activity log page shows H2 training updates" do
      sign_in_system(@user)

      # Create an activity log entry
      Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Updated H2 Training 'Test Training Program' (Round 1) for user 'Test User'",
        metadata: {
          h2_user_id: 1,
          h2_user_name: "Test User",
          assignment_name: "Test Training Program"
        }
      )

      # Navigate to activity logs
      visit mis2.activity_logs_path

      # Verify the activity log is displayed
      assert_text I18n.t("mis2.activity_logs.index.title")
      assert_text @user.name
      assert_text "Test Training Program"
      assert_text "Test User"
    end

    test "prevents date overlap for same user" do
      sign_in_system(@user)

      # Create another assignment for the same user with non-overlapping dates
      another_assignment = Mis2::H2::Assignment.find_or_create_by!(assignment_idx: 2) do |a|
        a.assignment_name = "Another Training"
      end

      Mis2::H2::AssignmentUser.find_or_create_by!(assignment_user_idx: 2) do |au|
        au.user = @h2_user
        au.assignment_record = another_assignment
        au.assignment_user_start = Date.current + 20.days
        au.assignment_user_end = Date.current + 27.days
        au.round = 1
        au.create_time = Time.current
      end

      visit mis2.edit_h2_assignment_path(@h2_user.user_idx)

      # Try to change dates of the first assignment to overlap with the second
      overlapping_start = (Date.current + 21.days).strftime("%Y-%m-%d")
      overlapping_end = (Date.current + 25.days).strftime("%Y-%m-%d")

      # Find the row for "Test Training Program" and update its dates
      row = find("tr", text: "Test Training Program")
      form_id = row.find("button.assignment-update-btn")[:form]

      execute_script("document.querySelector(\"input[name='start_date'][form='#{form_id}']\").value = '#{overlapping_start}'")
      execute_script("document.querySelector(\"input[name='end_date'][form='#{form_id}']\").value = '#{overlapping_end}'")
      execute_script("document.querySelector(\"input[name='start_date'][form='#{form_id}']\").dispatchEvent(new Event('input', { bubbles: true }))")

      accept_confirm do
        row.find("button.assignment-update-btn").click
      end

      # Verify overlap error message
      assert_text I18n.t("mis2.h2.assignments.alerts.overlap_error")
    end
  end
end
