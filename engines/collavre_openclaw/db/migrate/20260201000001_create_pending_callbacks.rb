class CreatePendingCallbacks < ActiveRecord::Migration[8.0]
  def change
    create_table :openclaw_pending_callbacks do |t|
      t.references :openclaw_account, null: false, foreign_key: { to_table: :openclaw_accounts }
      t.string :nonce, null: false, index: { unique: true }
      t.integer :creative_id
      t.integer :comment_id
      t.integer :thread_id
      t.text :context  # Use text for SQLite compatibility, serialize in model
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :openclaw_pending_callbacks, :expires_at
  end
end
