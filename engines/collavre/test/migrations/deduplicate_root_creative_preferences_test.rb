require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260922000000_deduplicate_root_creative_preferences")

class DeduplicateRootCreativePreferencesTest < ActiveSupport::TestCase
  test "PostgreSQL locks out inserts before cleanup without installing a rollout-incompatible index" do
    migration = DeduplicateRootCreativePreferences.new
    operations = []
    connection = Struct.new(:adapter_name).new("PostgreSQL")
    migration.define_singleton_method(:execute) { |sql| operations << sql.strip }
    migration.define_singleton_method(:add_index) { |*args, **options| operations << :index }
    migration.stub(:connection, connection) { migration.up }

    assert_equal "LOCK TABLE user_creative_preferences IN ACCESS EXCLUSIVE MODE", operations[0]
    assert_match(/\ADELETE FROM user_creative_preferences/, operations[1])
    assert_equal 2, operations.size
    assert_not DeduplicateRootCreativePreferences.disable_ddl_transaction
  end

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
    assert_difference "Collavre::UserCreativePreference.count", 1 do
      preference.insert_all([ { user_id: users(:one).id, expanded_status: {} } ],
        unique_by: :index_user_creative_preferences_on_creative_id_and_user_id)
    end
  end
end
