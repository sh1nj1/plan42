require_relative "../../../../test/application_system_test_case"

module Mis2
  class H3OrganizationTest < ApplicationSystemTestCase
    fixtures :users

    setup do
      @user = users(:one)

      @wait = create_h3_org_admin(
        org_attrs: { name: "대기병원", code: "W0001", type: "GENERAL_HOSPITAL" },
        dept_attrs: { medical_specialty: "내과" },
        admin_attrs: { login_id: "wait_admin", name: "대기관리자", phone: "01011111111", status: "WAIT" }
      )
      @org_wait = @wait[:org]
      @admin_wait = @wait[:admin]

      @active = create_h3_org_admin(
        org_attrs: { name: "활성병원", code: "A0001", type: "HOSPITAL", active_yn: true },
        dept_attrs: { medical_specialty: "외과" },
        admin_attrs: { login_id: "active_admin", name: "활성관리자", phone: "01022222222", status: "ACTIVE" }
      )
      @admin_active = @active[:admin]
    end

    teardown do
      cleanup_h3_test_data(@wait, @active)
    end

    test "view hospital list and search" do
      sign_in_system(@user)

      visit mis2.h3_organizations_path

      # Verify both hospitals are shown
      assert_text "대기병원"
      assert_text "활성병원"

      # Search by name
      fill_in "query", with: "대기"
      click_button I18n.t("mis2.h3.organizations.index.search_button")

      assert_text "대기병원"
      assert_no_text "활성병원"
    end

    test "filter by status chips" do
      sign_in_system(@user)

      # Test single status filter via URL
      visit mis2.h3_organizations_path(statuses: [ "WAIT" ])

      assert_text "대기병원"
      assert_no_text "활성병원"

      # Verify the WAIT chip has active class
      wait_chip = find(".status-filter-chip", text: I18n.t("mis2.h3.organizations.statuses.wait"))
      assert_includes wait_chip[:class], "active"

      # Test multiple status filter (OR) via URL
      visit mis2.h3_organizations_path(statuses: [ "WAIT", "ACTIVE" ])

      assert_text "대기병원"
      assert_text "활성병원"
    end

    test "approve pending hospital" do
      sign_in_system(@user)

      visit mis2.h3_organizations_path

      # Find the WAIT row and click approve button
      accept_confirm(I18n.t("mis2.h3.organizations.index.approve_confirm")) do
        within("tr", text: "대기병원") do
          click_button I18n.t("mis2.h3.organizations.index.approve_button")
        end
      end

      # Verify success message
      assert_text I18n.t("mis2.h3.organizations.approve_success")

      # Verify DB changes
      @admin_wait.reload
      assert_equal "ACTIVE", @admin_wait.status

      @org_wait.reload
      assert_equal true, @org_wait.active_yn

      # Verify activity log
      log = Mis2::ActivityLog.where(action: "h3_organization_approve").last
      assert_not_nil log
      assert_includes log.message, "대기병원"
    end

    test "approve button not shown for active hospitals" do
      sign_in_system(@user)

      visit mis2.h3_organizations_path

      within("tr", text: "활성병원") do
        assert_no_button I18n.t("mis2.h3.organizations.index.approve_button")
      end
    end

    test "cancel approval confirmation" do
      sign_in_system(@user)

      visit mis2.h3_organizations_path

      dismiss_confirm do
        within("tr", text: "대기병원") do
          click_button I18n.t("mis2.h3.organizations.index.approve_button")
        end
      end

      # Status should not change
      @admin_wait.reload
      assert_equal "WAIT", @admin_wait.status
    end
  end
end
