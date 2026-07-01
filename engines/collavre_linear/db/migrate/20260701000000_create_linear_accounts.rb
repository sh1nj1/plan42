class CreateLinearAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :linear_accounts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :linear_uid, null: false
      t.string :app_actor_id
      t.string :access_token, null: false
      t.string :refresh_token
      t.datetime :token_expires_at
      t.string :workspace_id
      t.string :workspace_name
      t.timestamps
    end

    add_index :linear_accounts, :linear_uid, unique: true
  end
end
