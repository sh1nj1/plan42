require "test_helper"

class Collavre::ApplicationHelperTest < ActionView::TestCase
  include Collavre::ApplicationHelper

  setup do
    @user = collavre_users(:admin)
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
    @user.update!(theme: "42")
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
end
