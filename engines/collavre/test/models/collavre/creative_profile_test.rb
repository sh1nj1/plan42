# engines/collavre/test/models/collavre/creative_profile_test.rb
require "test_helper"

module Collavre
  class CreativeProfileTest < ActiveSupport::TestCase
    setup { @user = Collavre::User.create!(name: "Ann", email: "ann@example.com", password: "password123") }

    test "profile_for creates a profile creative owned by the user" do
      profile = Collavre::Creative.profile_for(@user)
      assert_equal "profile", profile.data["kind"]
      assert_equal @user.id, profile.user_id
    end

    test "profile_for is idempotent" do
      first = Collavre::Creative.profile_for(@user)
      assert_no_difference -> { Collavre::Creative.profiles.where(user: @user).count } do
        assert_equal first.id, Collavre::Creative.profile_for(@user).id
      end
    end

    test "profile is a reserved metadata kind" do
      assert_includes Collavre::Creative.reserved_metadata_keys, "profile"
      assert_includes Collavre::Creative.reserved_metadata_keys, "skill"
    end
  end
end
