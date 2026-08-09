class ChangeCreativeWorkspaceEnabledDefaultToTrue < ActiveRecord::Migration[8.0]
  # Ledger of the rows this migration flipped, so `down` can restore the exact
  # previous values instead of leaving every user opted in. Dropped on rollback.
  BACKFILL_LEDGER = :creative_workspace_enabled_backfills

  # Lightweight stub so the backfill does not depend on the app model.
  class MigrationUser < ActiveRecord::Base
    self.table_name = :users
  end

  def up
    change_column_default :users, :creative_workspace_enabled, from: false, to: true

    create_table BACKFILL_LEDGER, id: false do |t|
      t.bigint :user_id, null: false, index: { unique: true }
    end

    # The preference shipped as opt-in only days ago, so every stored `false`
    # is the old default rather than a deliberate opt-out.
    execute <<~SQL.squish
      INSERT INTO #{BACKFILL_LEDGER} (user_id)
      SELECT id FROM users WHERE creative_workspace_enabled = #{false_literal}
    SQL
    MigrationUser.where(creative_workspace_enabled: false).update_all(creative_workspace_enabled: true)
  end

  def down
    # Restore only the rows this migration flipped; opt-ins made afterwards stay on.
    execute <<~SQL.squish
      UPDATE users SET creative_workspace_enabled = #{false_literal}
      WHERE id IN (SELECT user_id FROM #{BACKFILL_LEDGER})
    SQL
    drop_table BACKFILL_LEDGER, if_exists: true

    change_column_default :users, :creative_workspace_enabled, from: true, to: false
  end

  private

  def false_literal
    connection.quote(false)
  end
end
