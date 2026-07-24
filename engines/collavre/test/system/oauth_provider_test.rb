require_relative "../application_system_test_case"

class OauthProviderTest < ApplicationSystemTestCase
  # Generous wait for full-page navigations, which can queue behind other system
  # tests sharing the Puma server when the suite runs in parallel. Capybara's
  # default 2s is too tight under that load and caused flaky failures.
  NAV_WAIT = 15

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
    assert_button "Authorize"
    click_on "Authorize"

    # Consent is a plain full-page POST that renders the authorization code page.
    # Under parallel-suite load this navigation can take longer than Capybara's
    # default 2s wait, which left the assertion looking at the still-visible
    # consent screen and failing flakily. Wait explicitly for the navigation to
    # complete instead of relying on the default timeout.
    assert_no_content "Authorize Test Client to use your account?", wait: NAV_WAIT
    assert_content "Authorization code", wait: NAV_WAIT
    assert_selector "code#authorization_code", text: /.+/, wait: NAV_WAIT
  end
end
