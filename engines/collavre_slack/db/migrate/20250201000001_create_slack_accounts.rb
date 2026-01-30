class CreateSlackAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :slack_accounts do |t|
      t.references :user, null: false, foreign_key: { to_table: :users }
      t.string :team_id, null: false
      t.string :team_name, null: false
      t.string :access_token, null: false
      t.string :authed_user_id
      t.string :scopes
      t.datetime :token_expires_at

      t.timestamps
    end

    add_index :slack_accounts, :team_id, unique: true
  end
end
