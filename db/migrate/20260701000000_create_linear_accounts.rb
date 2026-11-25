class CreateLinearAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :linear_accounts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :linear_uid, null: false
      t.string :app_actor_id
      # OAuth tokens are stored via ActiveRecord encryption; the encrypted
      # envelope of a real Linear access/refresh token exceeds the 255-byte
      # `string` limit in PostgreSQL, so use `text` to avoid save failures.
      t.text :access_token, null: false
      t.text :refresh_token
      t.datetime :token_expires_at
      t.string :workspace_id
      t.string :workspace_name
      t.timestamps
    end

    add_index :linear_accounts, :linear_uid, unique: true
  end
end
