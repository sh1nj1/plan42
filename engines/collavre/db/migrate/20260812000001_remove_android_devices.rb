class RemoveAndroidDevices < ActiveRecord::Migration[8.0]
  ANDROID_DEVICE_CONSTRAINT = "devices_no_android_device_type".freeze

  def up
    if connection.supports_validate_constraints?
      # PostgreSQL can enforce a not-yet-validated constraint. This closes the
      # rolling-deploy window before removing existing registrations: an old
      # container may finish a request, but cannot recreate an Android token.
      add_check_constraint :devices, "device_type != 2", name: ANDROID_DEVICE_CONSTRAINT, validate: false
      execute "DELETE FROM devices WHERE device_type = 2"
      validate_check_constraint :devices, name: ANDROID_DEVICE_CONSTRAINT
    else
      # SQLite rebuilds the table to add a check constraint, so it cannot add
      # one while Android rows exist. The migration transaction serializes
      # writers, making the delete and constraint addition atomic here.
      execute "DELETE FROM devices WHERE device_type = 2"
      add_check_constraint :devices, "device_type != 2", name: ANDROID_DEVICE_CONSTRAINT
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Android device tokens cannot be restored"
  end
end
