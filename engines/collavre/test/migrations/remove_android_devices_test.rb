require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260812000001_remove_android_devices")

class RemoveAndroidDevicesTest < ActiveSupport::TestCase
  test "blocks Android registration before cleanup when the database supports unvalidated constraints" do
    calls = migration_calls(supports_validate_constraints: true)

    assert_equal %i[add_constraint delete validate_constraint], calls.map(&:first)
    assert_equal false, calls.first.last[:validate]
  end

  test "cleans up before adding the constraint on databases without unvalidated constraints" do
    calls = migration_calls(supports_validate_constraints: false)

    assert_equal %i[delete add_constraint], calls.map(&:first)
  end

  test "cannot be reversed after deleting Android device tokens" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      RemoveAndroidDevices.new.down
    end

    assert_includes error.message, "Android device tokens cannot be restored"
  end

  private

  def migration_calls(supports_validate_constraints:)
    migration = RemoveAndroidDevices.new
    connection = Object.new
    connection.define_singleton_method(:supports_validate_constraints?) { supports_validate_constraints }
    calls = []
    connection.define_singleton_method(:add_check_constraint) do |*, **options|
      calls << [ :add_constraint, options ]
    end
    connection.define_singleton_method(:execute) do |sql|
      calls << [ :delete, sql ]
    end
    connection.define_singleton_method(:validate_check_constraint) do |*, **options|
      calls << [ :validate_constraint, options ]
    end

    migration.stub(:connection, connection) do
      migration.up
    end

    calls
  end
end
