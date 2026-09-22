class DeduplicateRootCreativePreferences < ActiveRecord::Migration[8.0]
  def up
    # Rails holds this lock through cleanup in the DDL transaction.
    if connection.adapter_name == "PostgreSQL"
      execute "LOCK TABLE user_creative_preferences IN ACCESS EXCLUSIVE MODE"
    end

    # Keep the row read by the old client. Later duplicate inserts were unused.
    execute <<~SQL
      DELETE FROM user_creative_preferences
      WHERE creative_id IS NULL AND id NOT IN (
        SELECT MIN(id) FROM user_creative_preferences
        WHERE creative_id IS NULL GROUP BY user_id
      )
    SQL
    # Defer the partial unique index until the prior composite-targeted writer
    # is no longer a rollout or rollback candidate. It cannot handle that conflict.
  end

  def down
    # Removed duplicate rows cannot be reconstructed.
  end
end
