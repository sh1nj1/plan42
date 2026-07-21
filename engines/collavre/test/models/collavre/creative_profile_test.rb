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

    # A duplicate profile is a split-brain hazard: prompt edits could land on one
    # profile while agent execution reads another. A hard DB uniqueness index is
    # not portable here — the discriminator lives in the `data` json column, and
    # on Postgres `json ->>` is STABLE (not IMMUTABLE), so a partial-unique index
    # WHERE data->>'kind' = 'profile' is rejected at schema load. Instead every
    # profile lookup orders by id, so reads and writes converge on the oldest
    # profile and a transient race-created duplicate is harmless, never a split
    # brain. Both the write path (profile_for) and the read path
    # (profile_creative_if_present) must pick the same one.
    test "reads and writes converge on the oldest profile when a duplicate exists" do
      first = Collavre::Creative.profile_for(@user)
      second = Collavre::Creative.create!(
        description: @user.name.to_s,
        data: { "kind" => Collavre::Creative::PROFILE_KIND },
        user: @user,
        progress: 0.0
      )
      assert_operator second.id, :>, first.id, "second profile should be newer"

      assert_equal first.id, Collavre::Creative.profile_for(@user).id,
        "write path must target the oldest profile"
      assert_equal first.id, @user.profile_creative_if_present.id,
        "read path must return the same profile the write path targets"
    end

    # Profile and inbox share user_id but differ by kind; both must coexist.
    test "profile and inbox creatives coexist for the same user" do
      profile = Collavre::Creative.profile_for(@user)
      inbox = Collavre::Creative.inbox_for(@user)
      assert_not_equal profile.id, inbox.id
      assert_equal "profile", profile.data["kind"]
      assert_equal "inbox", inbox.data["kind"]
    end
  end
end
