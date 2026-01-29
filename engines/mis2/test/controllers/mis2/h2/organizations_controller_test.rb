# Controller test for H2 Organizations
require "test_helper"

module Mis2
  module H2
    class OrganizationsControllerTest < ActionDispatch::IntegrationTest
      fixtures :users

      setup do
        ensure_h2_schema_loaded!

        @user = users(:one)
        sign_in_as(@user)

        # Create test organizations
        @org1 = Mis2::H2::Organization.find_or_create_by!(organization_idx: 100) do |org|
          org.organization_name = "Seoul Hospital"
        end
        @org2 = Mis2::H2::Organization.find_or_create_by!(organization_idx: 101) do |org|
          org.organization_name = "Busan Medical Center"
        end
        @org3 = Mis2::H2::Organization.find_or_create_by!(organization_idx: 102) do |org|
          org.organization_name = "Seoul University Hospital"
        end
      end

      teardown do
        Mis2::H2::Organization.where(organization_idx: [ 100, 101, 102 ]).delete_all
      rescue ActiveRecord::StatementInvalid
        # Ignore if H2 tables don't exist (parallel test worker without schema)
      end

      test "search returns matching organizations" do
        get mis2.search_h2_organizations_path, params: { query: "Seoul" }, as: :json

        assert_response :success
        json = JSON.parse(response.body)

        assert_equal 2, json.length
        names = json.map { |o| o["organization_name"] }
        assert_includes names, "Seoul Hospital"
        assert_includes names, "Seoul University Hospital"
      end

      test "search returns empty array for no matches" do
        get mis2.search_h2_organizations_path, params: { query: "Nonexistent" }, as: :json

        assert_response :success
        json = JSON.parse(response.body)

        assert_equal [], json
      end

      test "search returns empty array for blank query" do
        get mis2.search_h2_organizations_path, params: { query: "" }, as: :json

        assert_response :success
        json = JSON.parse(response.body)

        assert_equal [], json
      end

      private

      def sign_in_as(user)
        post session_path, params: { email: user.email, password: "password" }
      end
    end
  end
end
