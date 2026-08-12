require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260812000001_remove_android_devices")

class RemoveAndroidDevicesTest < ActiveSupport::TestCase
  test "cannot be reversed after deleting Android device tokens" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      RemoveAndroidDevices.new.down
    end

    assert_includes error.message, "Android device tokens cannot be restored"
  end
end
