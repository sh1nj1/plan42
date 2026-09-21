class ChangeCreativeWorkspaceEnabledDefaultToTrue < ActiveRecord::Migration[8.0]
  # Lightweight stub so the backfill does not depend on the app model.
  class MigrationUser < ActiveRecord::Base
    self.table_name = :users
  end

  def up
    change_column_default :users, :creative_workspace_enabled, from: false, to: true

    # The preference shipped as opt-in only days ago, so every stored `false`
    # is the old default rather than a deliberate opt-out.
    MigrationUser.where(creative_workspace_enabled: false).update_all(creative_workspace_enabled: true)
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "cannot distinguish backfilled defaults from post-migration user opt-ins"
  end
end
