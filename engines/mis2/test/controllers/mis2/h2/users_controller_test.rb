# Controller test for H2 Users
require "test_helper"

module Mis2
  module H2
    class UsersControllerTest < ActionDispatch::IntegrationTest
      fixtures :users

      setup do
        ensure_h2_schema_loaded!

        @user = users(:one)
        sign_in_as(@user)

        # Create test organizations
        @org1 = Mis2::H2::Organization.find_or_create_by!(organization_idx: 200) do |org|
          org.organization_name = "Test Organization A"
        end
        @org2 = Mis2::H2::Organization.find_or_create_by!(organization_idx: 201) do |org|
          org.organization_name = "Test Organization B"
        end

        # Create test H2 user
        @h2_user = Mis2::H2::User.find_or_create_by!(user_idx: 200) do |u|
          u.name = "Test H2 User"
          u.date_of_birth = "19950515"
          u.phone = "01098765432"
          u.organization_idx = 200
        end
      end

      teardown do
        Mis2::H2::User.where(user_idx: 200).delete_all
        Mis2::H2::Organization.where(organization_idx: [ 200, 201 ]).delete_all
        Mis2::ActivityLog.where(action: "h2_organization_update").delete_all
      rescue ActiveRecord::StatementInvalid
        # Ignore if H2 tables don't exist (parallel test worker without schema)
      end

      test "update_organization changes user organization" do
        patch mis2.update_organization_h2_user_path(@h2_user.user_idx),
              params: { organization_idx: @org2.organization_idx },
              as: :json

        assert_response :success
        json = JSON.parse(response.body)

        assert json["success"]
        assert_equal "Test Organization B", json["organization_name"]

        # Verify database was updated
        @h2_user.reload
        assert_equal @org2.organization_idx, @h2_user.organization_idx
      end

      test "update_organization creates activity log" do
        assert_difference "Mis2::ActivityLog.count", 1 do
          patch mis2.update_organization_h2_user_path(@h2_user.user_idx),
                params: { organization_idx: @org2.organization_idx },
                as: :json
        end

        activity_log = Mis2::ActivityLog.last
        assert_equal "h2_organization_update", activity_log.action
        assert_equal @user.id, activity_log.user_id
        assert_includes activity_log.message, "Test H2 User"
        assert_includes activity_log.message, "Test Organization A"
        assert_includes activity_log.message, "Test Organization B"
      end

      test "update_organization returns error for nonexistent user" do
        patch mis2.update_organization_h2_user_path(99999),
              params: { organization_idx: @org2.organization_idx },
              as: :json

        assert_response :not_found
        json = JSON.parse(response.body)

        assert_not json["success"]
      end

      test "update_organization returns error for nonexistent organization" do
        patch mis2.update_organization_h2_user_path(@h2_user.user_idx),
              params: { organization_idx: 99999 },
              as: :json

        assert_response :not_found
        json = JSON.parse(response.body)

        assert_not json["success"]
      end

      private

      def sign_in_as(user)
        post session_path, params: { email: user.email, password: "password" }
      end
    end
  end
end
