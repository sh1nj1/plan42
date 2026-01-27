class UpdatePermissions < ActiveRecord::Migration[6.1]
  def up
    execute <<~SQL
      UPDATE creative_shares
      SET permission = CASE permission
        WHEN 1 THEN 0
        WHEN 2 THEN 2
        WHEN 3 THEN 2
        ELSE permission
      END
    SQL
    execute <<~SQL
      UPDATE invitations
      SET permission = CASE permission
        WHEN 1 THEN 0
        WHEN 2 THEN 2
        WHEN 3 THEN 2
        ELSE permission
      END
    SQL
  end

  def down
    execute <<~SQL
      UPDATE creative_shares
      SET permission = CASE permission
        WHEN 0 THEN 1
        WHEN 1 THEN 2
        WHEN 2 THEN 3
        ELSE permission
      END
    SQL
    execute <<~SQL
      UPDATE invitations
      SET permission = CASE permission
        WHEN 0 THEN 1
        WHEN 1 THEN 2
        WHEN 2 THEN 3
        ELSE permission
      END
    SQL
  end
end
