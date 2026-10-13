require "test_helper"

class ProfilePreferencesTest < ActiveSupport::TestCase
  test "empty registry permits no extension attributes" do
    Collavre::ProfilePreferences.stub(:registrations, {}) do
      assert_empty Collavre::ProfilePreferences.attributes
    end
  end

  test "registrations normalize deduplicate and replace per engine" do
    Collavre::ProfilePreferences.stub(:registrations, {}) do
      Collavre::ProfilePreferences.register(:first, "color", :color)
      Collavre::ProfilePreferences.register(:second, :color, :size)
      assert_equal [ :color, :size ], Collavre::ProfilePreferences.attributes
      Collavre::ProfilePreferences.register(:first, :theme)
      assert_equal [ :theme, :color, :size ], Collavre::ProfilePreferences.attributes
    end
  end
end
