# System test for H2 Organization change via modal
# Uses main app context for full Rails stack

require_relative "../../../../test/application_system_test_case"

module Mis2
  class H2OrganizationTest < ApplicationSystemTestCase
    fixtures :users

    setup do
      @user = users(:one)

      # Create test organizations
      @org1 = Mis2::H2::Organization.find_or_create_by!(organization_idx: 300) do |org|
        org.organization_name = "Original Hospital"
      end
      @org2 = Mis2::H2::Organization.find_or_create_by!(organization_idx: 301) do |org|
        org.organization_name = "New Hospital"
      end

      # Create H2 test user
      @h2_user = Mis2::H2::User.find_or_create_by!(user_idx: 300) do |u|
        u.name = "Organization Test User"
        u.date_of_birth = "19880303"
        u.phone = "01011112222"
        u.organization_idx = 300
      end
    end

    teardown do
      Mis2::H2::User.where(user_idx: 300).delete_all
      Mis2::H2::Organization.where(organization_idx: [ 300, 301 ]).delete_all
      Mis2::ActivityLog.where(action: "h2_organization_update").delete_all
    end

    test "change user organization via modal" do
      sign_in_system(@user)

      # Navigate to H2 assignments
      visit mis2.h2_assignments_path

      # Search for the user
      fill_in "query", with: "Organization Test User"
      click_button I18n.t("mis2.h2.assignments.index.search_button")

      # Verify user appears with original organization
      assert_text "Organization Test User"
      assert_text "Original Hospital"

      # Click the edit button for organization
      find("button[data-user-id='300']").click

      # Verify modal is open
      assert_selector ".organization-modal-overlay", visible: true
      assert_text I18n.t("mis2.h2.organizations.modal_title")
      assert_text "Organization Test User"

      # Verify update button is initially disabled
      update_btn = find("button", text: I18n.t("mis2.h2.organizations.btn_update"))
      assert update_btn.disabled?

      # Search for new organization
      fill_in placeholder: I18n.t("mis2.h2.organizations.search_placeholder"), with: "New Hospital"

      # Wait for search results
      assert_selector ".organization-result-item", text: "New Hospital", wait: 5

      # Select the new organization (just highlights, doesn't apply yet)
      find(".organization-result-item", text: "New Hospital").click

      # Verify item is selected and update button is now enabled
      assert_selector ".organization-result-item.selected", text: "New Hospital"
      assert_not update_btn.disabled?

      # Click update button and accept confirmation
      accept_confirm do
        update_btn.click
      end

      # Verify modal closed and organization updated in table
      assert_no_selector ".organization-modal-overlay", visible: true
      assert_text "New Hospital"

      # Verify database was updated
      @h2_user.reload
      assert_equal @org2.organization_idx, @h2_user.organization_idx

      # Verify activity log was created
      activity_log = Mis2::ActivityLog.last
      assert_not_nil activity_log
      assert_equal "h2_organization_update", activity_log.action
      assert_equal @user.id, activity_log.user_id
      assert_includes activity_log.message, "Organization Test User"
      assert_includes activity_log.message, "Original Hospital"
      assert_includes activity_log.message, "New Hospital"
    end

    test "modal closes on escape key" do
      sign_in_system(@user)

      visit mis2.h2_assignments_path
      fill_in "query", with: "Organization Test User"
      click_button I18n.t("mis2.h2.assignments.index.search_button")

      # Open modal
      find("button[data-user-id='300']").click
      assert_selector ".organization-modal-overlay", visible: true

      # Press Escape
      find(".organization-search-input").send_keys(:escape)

      # Verify modal closed
      assert_no_selector ".organization-modal-overlay", visible: true
    end

    test "modal closes on close button click" do
      sign_in_system(@user)

      visit mis2.h2_assignments_path
      fill_in "query", with: "Organization Test User"
      click_button I18n.t("mis2.h2.assignments.index.search_button")

      # Open modal
      find("button[data-user-id='300']").click
      assert_selector ".organization-modal-overlay", visible: true

      # Click close button
      find(".organization-modal-close").click

      # Verify modal closed
      assert_no_selector ".organization-modal-overlay", visible: true
    end

    test "modal closes on cancel button click" do
      sign_in_system(@user)

      visit mis2.h2_assignments_path
      fill_in "query", with: "Organization Test User"
      click_button I18n.t("mis2.h2.assignments.index.search_button")

      # Open modal
      find("button[data-user-id='300']").click
      assert_selector ".organization-modal-overlay", visible: true

      # Click cancel button
      click_button I18n.t("mis2.h2.organizations.btn_cancel")

      # Verify modal closed
      assert_no_selector ".organization-modal-overlay", visible: true
    end

    test "search shows no results message" do
      sign_in_system(@user)

      visit mis2.h2_assignments_path
      fill_in "query", with: "Organization Test User"
      click_button I18n.t("mis2.h2.assignments.index.search_button")

      # Open modal
      find("button[data-user-id='300']").click

      # Search for nonexistent organization
      fill_in placeholder: I18n.t("mis2.h2.organizations.search_placeholder"), with: "Nonexistent Hospital XYZ"

      # Wait and verify no results message
      sleep 0.5  # Wait for debounce
      assert_text I18n.t("mis2.h2.organizations.no_results")
    end
  end
end
