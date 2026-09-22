require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260922000002_deduplicate_root_creative_preferences")

class DeduplicateRootCreativePreferencesTest < ActiveSupport::TestCase
  test "PostgreSQL locks out inserts before cleanup without installing a rollout-incompatible index" do
    migration = DeduplicateRootCreativePreferences.new
    operations = []
    connection = Struct.new(:adapter_name).new("PostgreSQL")
    migration.define_singleton_method(:execute) { |sql| operations << sql.strip }
    migration.define_singleton_method(:merge_duplicate_roots) { operations << :merge }
    migration.define_singleton_method(:add_index) { |*args, **options| operations << :index }
    migration.stub(:connection, connection) { migration.up }

    assert_equal "LOCK TABLE user_creative_preferences IN ACCESS EXCLUSIVE MODE", operations[0]
    assert_equal :merge, operations[1]
    assert_equal 2, operations.size
    assert_not DeduplicateRootCreativePreferences.disable_ddl_transaction
  end

  test "merges duplicate root state into the previously read row and preserves other preferences" do
    migration = DeduplicateRootCreativePreferences.new
    migration.down
    preference = Collavre::UserCreativePreference
    root = preference.create!(user: users(:one), expanded_status: { "1" => true, "shared" => true })
    duplicate = preference.create!(user: users(:one), expanded_status: { "2" => true, "shared" => false })
    scoped = preference.create!(user: users(:one), creative: creatives(:tshirt), expanded_status: { "3" => true })
    other = preference.create!(user: users(:two), expanded_status: { "4" => true })

    third = preference.create!(user: users(:one), expanded_status: { "5" => true })
    other_duplicate = preference.create!(user: users(:two), expanded_status: { "6" => true })

    migration.up

    assert_equal({ "1" => true, "2" => true, "5" => true, "shared" => false }, root.reload.expanded_status)
    refute preference.exists?(duplicate.id)
    refute preference.exists?(third.id)
    refute preference.exists?(other_duplicate.id)
    assert_equal({ "3" => true }, scoped.reload.expanded_status)
    assert_equal({ "4" => true, "6" => true }, other.reload.expanded_status)
    snapshot = preference.order(:id).map(&:attributes)
    migration.up
    assert_equal snapshot, preference.order(:id).map(&:attributes)
    assert_difference "Collavre::UserCreativePreference.count", 1 do
      preference.insert_all([ { user_id: users(:one).id, expanded_status: {} } ],
        unique_by: :index_user_creative_preferences_on_creative_id_and_user_id)
    end
  end

  test "merges empty duplicate state without invoking application validations" do
    preference = Collavre::UserCreativePreference
    preference.insert_all!([
      { user_id: users(:one).id, expanded_status: {} },
      { user_id: users(:one).id, expanded_status: {} }
    ])
    roots = preference.where(user: users(:one), creative_id: nil)
    keeper_id = roots.minimum(:id)

    DeduplicateRootCreativePreferences.new.up

    assert_equal [ keeper_id ], roots.pluck(:id)
    assert_equal({}, roots.first.expanded_status)
  end
end
