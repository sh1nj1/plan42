require "test_helper"

class OauthAuthControllersTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
  end

  test "github auth callback redirects to creatives_path for logged in user" do
    sign_in_as(@user, password: "password")

    github_auth_hash = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "12345",
      info: { nickname: "testuser" },
      credentials: { token: "github_token_123" }
    )

    # Simulate the callback with omniauth.auth set
    get collavre.auth_github_callback_path, env: { "omniauth.auth" => github_auth_hash }

    assert_redirected_to collavre.creatives_path
    assert_equal I18n.t("collavre.github_auth.connected"), flash[:notice]
  end

  test "github auth callback redirects to login when not authenticated for new account" do
    github_auth_hash = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "99999",
      info: { nickname: "newuser" },
      credentials: { token: "github_token_new" }
    )

    get collavre.auth_github_callback_path, env: { "omniauth.auth" => github_auth_hash }

    assert_redirected_to collavre.new_session_path
    assert_equal I18n.t("collavre.github_auth.login_first"), flash[:alert]
  end

  test "notion auth callback redirects to creatives_path for logged in user" do
    sign_in_as(@user, password: "password")

    notion_auth_hash = OmniAuth::AuthHash.new(
      provider: "notion",
      uid: "notion-12345",
      info: { name: "My Workspace" },
      credentials: { token: "notion_token_123" }
    )

    get collavre.auth_notion_callback_path, env: { "omniauth.auth" => notion_auth_hash }

    assert_redirected_to collavre.creatives_path
    assert_equal I18n.t("collavre.notion_auth.connected"), flash[:notice]
  end

  test "notion auth callback redirects to login when not authenticated for new account" do
    notion_auth_hash = OmniAuth::AuthHash.new(
      provider: "notion",
      uid: "notion-99999",
      info: { name: "New Workspace" },
      credentials: { token: "notion_token_new" }
    )

    get collavre.auth_notion_callback_path, env: { "omniauth.auth" => notion_auth_hash }

    assert_redirected_to collavre.new_session_path
    assert_equal I18n.t("collavre.notion_auth.login_first"), flash[:alert]
  end
end
