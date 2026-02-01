class CreateOpenclawAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :openclaw_accounts do |t|
      t.references :user, null: false, foreign_key: { to_table: :users }, index: { unique: true }
      t.string :gateway_url, null: false
      t.string :webhook_secret
      t.string :api_token
      t.string :channel_id
      t.text :description

      t.timestamps
    end
  end
end
