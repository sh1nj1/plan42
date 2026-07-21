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
    # profile (via the generic Creative tree) while agent execution reads another.
    # A partial unique index (index_creatives_on_user_id_profile_unique) enforces
    # one profile per user at the DB, so the duplicate can never exist. This is
    # portable on the current `data` json column: `json ->>`
    # (json_object_field_text) is IMMUTABLE on Postgres (verified pg14/pg16), so
    # the partial predicate is accepted at schema load, and SQLite enforces it.
    test "the database rejects a second profile creative for the same user" do
      Collavre::Creative.profile_for(@user)
      assert_raises(ActiveRecord::RecordNotUnique) do
        Collavre::Creative.create!(
          description: @user.name.to_s,
          data: { "kind" => Collavre::Creative::PROFILE_KIND },
          user: @user,
          progress: 0.0
        )
      end
    end

    # profile_for creates via create_or_find_by!: a create that loses the race
    # (unique-index violation) must resolve to the surviving row, not raise and
    # not add a second profile. Exercise that path directly against the real
    # scope, since profile_for's read-first fast path would otherwise short it.
    test "create_or_find_by resolves a lost create race to the surviving profile" do
      first = Collavre::Creative.profile_for(@user)
      resolved = nil
      assert_no_difference -> { Collavre::Creative.profiles.where(user: @user).count } do
        assert_nothing_raised do
          resolved = Collavre::Creative.profiles.create_or_find_by!(user: @user) do |creative|
            creative.description = @user.name.to_s
            creative.data = { "kind" => Collavre::Creative::PROFILE_KIND }
            creative.progress = 0.0
          end
        end
      end
      assert_equal first.id, resolved.id
    end

    # The State A migration collapses any pre-index duplicate profiles onto the
    # oldest before adding the unique index. Each duplicate Creative has a `Main`
    # topic (after_create :create_main_topic) behind a non-cascading
    # topics.creative_id FK, so a raw delete_all would be rejected on Postgres and
    # leave orphaned topics on SQLite. The collapse must destroy through the model
    # so the Main topic goes with it.
    test "collapse_duplicate_profiles removes duplicates and their Main topics" do
      conn = Collavre::Creative.connection
      index = "index_creatives_on_user_id_profile_unique"
      conn.remove_index :creatives, name: index
      begin
        keeper = Collavre::Creative.profile_for(@user)
        duplicate = Collavre::Creative.create!(
          description: @user.name.to_s,
          data: { "kind" => Collavre::Creative::PROFILE_KIND },
          user: @user,
          progress: 0.0
        )
        dup_topic_id = duplicate.topics.find_by(name: Collavre::Creative::MAIN_TOPIC_NAME).id

        require Rails.root.join("engines/collavre/db/migrate/20260721000010_add_unique_index_to_profile_creatives").to_s
        AddUniqueIndexToProfileCreatives.new.send(:collapse_duplicate_profiles!)

        assert Collavre::Creative.exists?(keeper.id), "oldest profile must survive"
        assert_not Collavre::Creative.exists?(duplicate.id), "duplicate profile must be removed"
        assert_not Collavre::Topic.exists?(dup_topic_id), "duplicate's Main topic must not orphan"
      ensure
        conn.add_index :creatives, :user_id, unique: true,
                       where: "data->>'kind' = 'profile'", name: index
      end
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
