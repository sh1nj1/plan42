# Controller test for H3 Organizations
require "test_helper"

module Mis2
  module H3
    class OrganizationsControllerTest < ActionDispatch::IntegrationTest
      fixtures :users

      setup do
        ensure_h3_schema_loaded!

        @user = users(:one)
        sign_in_as(@user)

        @wait = create_h3_org_admin(
          org_attrs: { name: "서울병원", code: "12345", type: "GENERAL_HOSPITAL" },
          dept_attrs: { medical_specialty: "내과" },
          admin_attrs: { login_id: "admin1", name: "김관리자", phone: "01012345678", status: "WAIT" }
        )
        @org = @wait[:org]
        @dept = @wait[:dept]
        @admin_wait = @wait[:admin]

        @active = create_h3_org_admin(
          org_attrs: { name: "부산의료원", code: "67890", type: "HOSPITAL", active_yn: true },
          dept_attrs: { medical_specialty: "외과" },
          admin_attrs: { login_id: "admin2", name: "이관리자", phone: "01098765432", status: "ACTIVE" }
        )
        @org2 = @active[:org]
        @dept2 = @active[:dept]
        @admin_active = @active[:admin]
      end

      teardown do
        cleanup_h3_test_data(@wait, @active)
      end

      test "index shows hospital list" do
        get mis2.h3_organizations_path

        assert_response :success
        assert_match "서울병원", response.body
        assert_match "부산의료원", response.body
      end

      test "index filters by status" do
        get mis2.h3_organizations_path, params: { statuses: [ "WAIT" ] }

        assert_response :success
        assert_match "서울병원", response.body
        assert_no_match "부산의료원", response.body
      end

      test "index filters by multiple statuses (OR)" do
        get mis2.h3_organizations_path, params: { statuses: [ "WAIT", "ACTIVE" ] }

        assert_response :success
        assert_match "서울병원", response.body
        assert_match "부산의료원", response.body
      end

      test "index searches by hospital name" do
        get mis2.h3_organizations_path, params: { query: "서울" }

        assert_response :success
        assert_match "서울병원", response.body
        assert_no_match "부산의료원", response.body
      end

      test "index searches by hospital code" do
        get mis2.h3_organizations_path, params: { query: "12345" }

        assert_response :success
        assert_match "서울병원", response.body
        assert_no_match "부산의료원", response.body
      end

      test "index paginates results" do
        # Create 21 additional admins to trigger pagination
        extras = []

        21.times do |i|
          extras << create_h3_org_admin(
            org_attrs: { name: "Hospital #{i}", code: "P#{i}", type: "HOSPITAL" },
            dept_attrs: { medical_specialty: "과#{i}" },
            admin_attrs: { login_id: "p#{i}", name: "Admin #{i}", status: "WAIT" }
          )
        end

        get mis2.h3_organizations_path
        assert_response :success
        # Should show pagination (total = 23, per_page = 20)
        assert_match I18n.t("mis2.common.pagination.next"), response.body

        # Page 2 should also work
        get mis2.h3_organizations_path, params: { page: 2 }
        assert_response :success
      ensure
        cleanup_h3_test_data(*extras) if extras
      end

      test "approve changes status from WAIT to ACTIVE" do
        patch mis2.approve_h3_organization_path(@admin_wait)

        assert_redirected_to mis2.h3_organizations_path

        @admin_wait.reload
        assert_equal "ACTIVE", @admin_wait.status

        @org.reload
        assert_equal true, @org.active_yn
      end

      test "approve creates activity log" do
        assert_difference "Mis2::ActivityLog.count", 1 do
          patch mis2.approve_h3_organization_path(@admin_wait)
        end

        activity_log = Mis2::ActivityLog.where(action: "h3_organization_approve").last
        assert_not_nil activity_log
        assert_equal "h3_organization_approve", activity_log.action
        assert_equal @user.id, activity_log.user_id
        assert_includes activity_log.message, "서울병원"
        assert_includes activity_log.message, "김관리자"
      end

      test "approve rejects non-WAIT status" do
        patch mis2.approve_h3_organization_path(@admin_active)

        assert_redirected_to mis2.h3_organizations_path
        follow_redirect!
        assert_match I18n.t("mis2.h3.organizations.approve_not_wait"), response.body
      end

      test "approve with nonexistent id returns error" do
        patch mis2.approve_h3_organization_path(id: 99999)

        assert_redirected_to mis2.h3_organizations_path
        follow_redirect!
        assert_match I18n.t("mis2.h3.organizations.not_found"), response.body
      end

      private

      def sign_in_as(user)
        post session_path, params: { email: user.email, password: "password" }
      end
    end
  end
end
