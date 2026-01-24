require "application_system_test_case"

class OauthProviderTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "test@example.com",
      password: "password",
      name: "Test User",
      email_verified_at: Time.current
    )
    @application = Doorkeeper::Application.create!(
      name: "Test Client",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "public",
      owner: @user
    )
  end

  test "authorizing a client application" do
    sign_in_via_ui(@user, password: "password")

    visit oauth_authorization_url(
      client_id: @application.uid,
      redirect_uri: @application.redirect_uri,
      response_type: "code",
      scope: "public"
    )

    assert_content "Authorize Test Client to use your account?"
    click_on "Authorize"

    assert_content "Authorization code"
    assert_selector "code", text: /.+/
  end
end
