require "test_helper"

module Oauth
  class ApplicationsControllerTest < ActionDispatch::IntegrationTest
    # Included by default in test_helper.rb: include IntegrationAuthHelper

    setup do
      @user = users(:one)
      sign_in_as @user, password: "password", follow_redirect: true
      @application = Doorkeeper::Application.create!(name: "Test App", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", owner: @user, confidential: true, scopes: "public write")
    end

    test "should get index" do
      get oauth_applications_url
      assert_response :success
    end



    test "should create access token with default expiration" do
      assert_difference("Doorkeeper::AccessToken.count") do
        post create_access_token_oauth_application_url(@application), params: { expiration_type: "1_month" }
      end

      token = Doorkeeper::AccessToken.last
      assert_equal @application.id, token.application_id
      assert_equal @user.id, token.resource_owner_id
      # Default expiration is 1 month (approx 30 days)
      assert_in_delta 1.month.to_i, token.expires_in, 10
    end

    test "should create access token with custom expiration" do
      post create_access_token_oauth_application_url(@application), params: { expiration_type: "custom", expires_in_days: "10" }
      token = Doorkeeper::AccessToken.last
      assert_in_delta 10.days.to_i, token.expires_in, 10
    end

    test "should create access token with never expires" do
      post create_access_token_oauth_application_url(@application), params: { expiration_type: "never" }
      token = Doorkeeper::AccessToken.last
      assert_nil token.expires_in
    end

    test "should respect application scopes" do
      # Application has scopes "public write"
      # Controller logic should assign these scopes
      post create_access_token_oauth_application_url(@application), params: { expiration_type: "1_month" }
      token = Doorkeeper::AccessToken.last
      assert_equal "public write", token.scopes.to_s
    end

    test "should destroy access token" do
      token = Doorkeeper::AccessToken.create!(application: @application, resource_owner_id: @user.id, scopes: "public")

      assert_difference("Doorkeeper::AccessToken.count", 0) do # Doesn't delete record, just revokes
        delete destroy_access_token_oauth_application_url(@application, token_id: token.id)
      end

      token.reload
      assert token.revoked?
      assert_redirected_to oauth_application_url(@application)
    end

    test "should not destroy access token of another user" do
      other_user = users(:two)
      token = Doorkeeper::AccessToken.create!(application: @application, resource_owner_id: other_user.id, scopes: "public")

      delete destroy_access_token_oauth_application_url(@application, token_id: token.id)

      token.reload
      assert_not token.revoked?
    end
  end
end
