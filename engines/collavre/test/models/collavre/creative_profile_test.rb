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

    test "kind discriminator is a reserved metadata key" do
      # `kind` scopes profile/inbox/skill discovery; it must survive a metadata
      # save that omits it, or the profile becomes undiscoverable and duplicates.
      assert_includes Collavre::Creative.reserved_metadata_keys, "kind"
    end

    test "preserving reserved keys keeps a profile discoverable after a metadata save" do
      profile = Collavre::Creative.profile_for(@user)
      # Simulate update_metadata's preservation loop with a payload omitting kind.
      incoming = { "theme" => "dark" }
      Collavre::Creative.reserved_metadata_keys.each do |key|
        if profile.data.key?(key)
          incoming[key] = profile.data[key]
        else
          incoming.delete(key)
        end
      end
      profile.update!(data: incoming)
      assert_equal profile.id, Collavre::Creative.profile_for(@user).id
      assert_equal "profile", profile.reload.data["kind"]
    end
  end
end
