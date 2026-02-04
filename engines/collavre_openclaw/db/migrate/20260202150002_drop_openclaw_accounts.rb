class DropOpenclawAccounts < ActiveRecord::Migration[7.2]
  def up
    drop_table :openclaw_accounts
  end

  def down
    create_table :openclaw_accounts do |t|
      t.integer :user_id, null: false
      t.string :gateway_url, null: false
      t.string :api_key
      t.string :channel_id

      t.timestamps
    end

    add_index :openclaw_accounts, :user_id, unique: true
  end
end
