require "test_helper"

class Collavre::ApplicationHelperTest < ActionView::TestCase
  include Collavre::ApplicationHelper

  setup do
    @user = users(:one)
  end

  test "body_theme_class returns dark-mode for dark theme" do
    @user.update!(theme: "dark")
    Current.user = @user
    assert_equal "dark-mode", body_theme_class
  end

  test "body_theme_class returns light-mode for light theme" do
    @user.update!(theme: "light")
    Current.user = @user
    assert_equal "light-mode", body_theme_class
  end

  test "body_theme_class returns light-mode for custom theme" do
    custom = @user.user_themes.create!(name: "Forest", variables: { "--surface-bg" => "#f0f0f0" })
    @user.update!(theme: custom.id.to_s)
    Current.user = @user
    assert_equal "light-mode", body_theme_class
  end

  test "body_theme_class returns empty string when no theme" do
    @user.update!(theme: nil)
    Current.user = @user
    assert_equal "", body_theme_class
  end

  test "body_theme_class returns empty string when no user" do
    Current.user = nil
    assert_equal "", body_theme_class
  end

  test "desktop? recognizes the packaged desktop user agent" do
    @request.headers["HTTP_USER_AGENT"] = "CollavreDesktop/0.1.0"

    assert_predicate self, :desktop?
  end

  test "desktop? ignores browser user agents" do
    @request.headers["HTTP_USER_AGENT"] = "Mozilla/5.0"

    assert_not desktop?
  end
end
