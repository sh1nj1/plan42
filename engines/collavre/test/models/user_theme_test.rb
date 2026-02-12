require "test_helper"

class UserThemeTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "dark? returns true for dark background" do
    theme = @user.user_themes.create!(name: "Dark", variables: { "--surface-bg" => "#1a1a2e" })
    assert theme.dark?
  end

  test "dark? returns false for light background" do
    theme = @user.user_themes.create!(name: "Light", variables: { "--surface-bg" => "#f5f5f5" })
    assert_not theme.dark?
  end

  test "dark? returns false for mid-brightness (50% boundary)" do
    theme = @user.user_themes.create!(name: "Mid", variables: { "--surface-bg" => "#808080" })
    assert_not theme.dark?
  end

  test "dark? returns false when surface-bg is missing" do
    theme = @user.user_themes.create!(name: "No BG", variables: { "--color-brand" => "#ff0000" })
    assert_not theme.dark?
  end

  test "dark? returns false for non-hex format" do
    theme = @user.user_themes.create!(name: "OKLCH", variables: { "--surface-bg" => "oklch(50% 0.1 200)" })
    assert_not theme.dark?
  end
end
