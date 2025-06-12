class AddNonePermission < ActiveRecord::Migration[6.1]
  def up
    execute <<~SQL
      UPDATE creative_shares SET permission = permission + 1;
    SQL
    execute <<~SQL
      UPDATE invitations SET permission = permission + 1 WHERE permission IS NOT NULL;
    SQL
  end

  def down
    execute <<~SQL
      UPDATE creative_shares SET permission = permission - 1;
    SQL
    execute <<~SQL
      UPDATE invitations SET permission = permission - 1 WHERE permission IS NOT NULL;
    SQL
  end
end
