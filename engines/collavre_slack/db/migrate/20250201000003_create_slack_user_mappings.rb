class CreateSlackUserMappings < ActiveRecord::Migration[8.0]
  def change
    create_table :slack_user_mappings do |t|
      t.references :slack_account, null: false, foreign_key: { to_table: :slack_accounts }
      t.references :collavre_user, null: false, foreign_key: { to_table: :users }
      t.string :slack_user_id, null: false
      t.string :display_name
      t.string :email

      t.timestamps
    end

    add_index :slack_user_mappings, [ :slack_account_id, :slack_user_id ], unique: true
  end
end
