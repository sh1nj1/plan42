require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260929120000_add_actor_lookup_index_to_creative_change_sets")

class AddActorLookupIndexToCreativeChangeSetsTest < ActiveSupport::TestCase
  test "disables the DDL transaction for concurrent index operations" do
    assert AddActorLookupIndexToCreativeChangeSets.disable_ddl_transaction
  end

  test "creates and removes the PostgreSQL index concurrently" do
    assert_index_operations "PostgreSQL", :concurrently
  end

  test "creates and removes the SQLite index without a concurrent algorithm" do
    assert_index_operations "SQLite", nil
  end

  test "migration reverses and recreates the user-leading lookup index" do
    connection = ActiveRecord::Base.connection
    migration = AddActorLookupIndexToCreativeChangeSets.new
    columns = %w[user_id status actor_kind]

    assert connection.index_exists?(:creative_change_sets, columns)
    # Exercise real DDL inside the test transaction; concurrent options are tested separately.
    migration.stub(:concurrent_algorithm, nil) do
      migration.migrate(:down)
      refute connection.index_exists?(:creative_change_sets, columns)
      migration.migrate(:up)
    end
    assert connection.index_exists?(:creative_change_sets, columns)
  end

  private

  def assert_index_operations(adapter, algorithm)
    migration = AddActorLookupIndexToCreativeChangeSets.new
    connection = Struct.new(:adapter_name).new(adapter)
    calls = []
    %i[add_index remove_index].each do |operation|
      migration.define_singleton_method(operation) do |*args, **options|
        calls << [ operation, args, options ]
      end
    end

    migration.stub(:connection, connection) do
      migration.up
      migration.down
    end

    options = { name: "index_creative_change_sets_on_actor_lookup", algorithm: algorithm }
    assert_equal [
      [ :add_index, [ :creative_change_sets, [ :user_id, :status, :actor_kind ] ], options ],
      [ :remove_index, [ :creative_change_sets ], options ]
    ], calls
  end
end
