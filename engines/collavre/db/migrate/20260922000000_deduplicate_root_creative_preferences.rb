class DeduplicateRootCreativePreferences < ActiveRecord::Migration[8.0]
  def up
    # Rails holds this lock through cleanup and index creation in the DDL transaction.
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
    add_index :user_creative_preferences, :user_id, unique: true,
      where: "creative_id IS NULL", name: :index_root_creative_preferences_on_user_id
  end

  def down
    remove_index :user_creative_preferences, name: :index_root_creative_preferences_on_user_id
  end
end
