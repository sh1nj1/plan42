class MigrateWritePermissionsToAdmin < ActiveRecord::Migration[8.0]
  def up
    write = CreativeShare.permissions[:write]
    admin = CreativeShare.permissions[:admin]

    CreativeShare.where(permission: write).update_all(permission: admin)
    Invitation.where(permission: write).update_all(permission: admin)
  end

  def down
    write = CreativeShare.permissions[:write]
    admin = CreativeShare.permissions[:admin]

    CreativeShare.where(permission: admin).update_all(permission: write)
    Invitation.where(permission: admin).update_all(permission: write)
  end
end
