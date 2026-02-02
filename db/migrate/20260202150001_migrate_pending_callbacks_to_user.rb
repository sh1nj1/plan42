class MigratePendingCallbacksToUser < ActiveRecord::Migration[7.2]
  def up
    # Add user_id column
    add_column :openclaw_pending_callbacks, :user_id, :integer

    # Migrate existing data
    execute <<-SQL
      UPDATE openclaw_pending_callbacks
      SET user_id = (
        SELECT user_id FROM openclaw_accounts
        WHERE openclaw_accounts.id = openclaw_pending_callbacks.openclaw_account_id
      )
    SQL

    # Remove old foreign key and column
    remove_foreign_key :openclaw_pending_callbacks, :openclaw_accounts
    remove_index :openclaw_pending_callbacks, :openclaw_account_id
    remove_column :openclaw_pending_callbacks, :openclaw_account_id

    # Add new foreign key
    add_foreign_key :openclaw_pending_callbacks, :users
    add_index :openclaw_pending_callbacks, :user_id

    # Make user_id not null (after data migration)
    change_column_null :openclaw_pending_callbacks, :user_id, false
  end

  def down
    # Add back openclaw_account_id
    add_column :openclaw_pending_callbacks, :openclaw_account_id, :integer

    # Migrate data back (if openclaw_accounts still exists)
    execute <<-SQL
      UPDATE openclaw_pending_callbacks
      SET openclaw_account_id = (
        SELECT id FROM openclaw_accounts
        WHERE openclaw_accounts.user_id = openclaw_pending_callbacks.user_id
        LIMIT 1
      )
    SQL

    # Remove user foreign key
    remove_foreign_key :openclaw_pending_callbacks, :users
    remove_index :openclaw_pending_callbacks, :user_id
    remove_column :openclaw_pending_callbacks, :user_id

    # Add back original foreign key
    add_foreign_key :openclaw_pending_callbacks, :openclaw_accounts
    add_index :openclaw_pending_callbacks, :openclaw_account_id
    change_column_null :openclaw_pending_callbacks, :openclaw_account_id, false
  end
end
