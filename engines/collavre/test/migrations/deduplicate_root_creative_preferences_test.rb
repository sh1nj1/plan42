require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260922000000_deduplicate_root_creative_preferences")

class DeduplicateRootCreativePreferencesTest < ActiveSupport::TestCase
  test "keeps the previously read root row and leaves scoped and other user preferences intact" do
    migration = DeduplicateRootCreativePreferences.new
    migration.down
    preference = Collavre::UserCreativePreference
    root = preference.create!(user: users(:one), expanded_status: { "1" => true })
    duplicate = preference.create!(user: users(:one), expanded_status: { "2" => true })
    scoped = preference.create!(user: users(:one), creative: creatives(:tshirt), expanded_status: { "3" => true })
    other = preference.create!(user: users(:two), expanded_status: { "4" => true })

    migration.up

    assert_equal({ "1" => true }, root.reload.expanded_status)
    refute preference.exists?(duplicate.id)
    assert preference.exists?(scoped.id)
    assert preference.exists?(other.id)
    assert_raises(ActiveRecord::RecordNotUnique) do
      preference.insert_all!([ { user_id: users(:one).id, expanded_status: {} } ])
    end
  end
end
