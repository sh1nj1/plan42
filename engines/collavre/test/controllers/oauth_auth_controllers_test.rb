require "test_helper"

class OauthAuthControllersTest < ActionDispatch::IntegrationTest
  setup do
    OmniAuth.config.test_mode = true
    @user = users(:one)
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.mock_auth[:notion] = nil
  end

  test "github auth callback redirects to creatives_path for logged in user" do
    sign_in_as(@user, password: "password")

    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "12345",
      info: { nickname: "testuser" },
      credentials: { token: "github_token_123" }
    )

    post "/auth/github/callback"

    assert_redirected_to collavre.creatives_path
    assert_equal I18n.t("collavre.github_auth.connected"), flash[:notice]
  end

  test "github auth callback redirects to login when not authenticated for new account" do
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "99999",
      info: { nickname: "newuser" },
      credentials: { token: "github_token_new" }
    )

    post "/auth/github/callback"

    assert_redirected_to collavre.new_session_path
    assert_equal I18n.t("collavre.github_auth.login_first"), flash[:alert]
  end

  test "notion auth callback redirects to creatives_path for logged in user" do
    sign_in_as(@user, password: "password")

    OmniAuth.config.mock_auth[:notion] = OmniAuth::AuthHash.new(
      provider: "notion",
      uid: "notion-12345",
      info: { name: "My Workspace" },
      credentials: { token: "notion_token_123" }
    )

    post "/auth/notion/callback"

    assert_redirected_to collavre.creatives_path
    assert_equal I18n.t("collavre.notion_auth.connected"), flash[:notice]
  end

  test "notion auth callback redirects to login when not authenticated for new account" do
    OmniAuth.config.mock_auth[:notion] = OmniAuth::AuthHash.new(
      provider: "notion",
      uid: "notion-99999",
      info: { name: "New Workspace" },
      credentials: { token: "notion_token_new" }
    )

    post "/auth/notion/callback"

    assert_redirected_to collavre.new_session_path
    assert_equal I18n.t("collavre.notion_auth.login_first"), flash[:alert]
  end
end
