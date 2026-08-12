class RemoveAndroidDevices < ActiveRecord::Migration[8.0]
  def up
    execute "DELETE FROM devices WHERE device_type = 2"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Android device tokens cannot be restored"
  end
end
