class CreateSlackChannelLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :slack_channel_links do |t|
      t.references :creative, null: false, foreign_key: { to_table: :creatives }
      t.references :slack_account, null: false, foreign_key: { to_table: :slack_accounts }
      t.string :channel_id, null: false
      t.string :channel_name, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.boolean :is_active, null: false, default: true

      t.timestamps
    end

    add_index :slack_channel_links, [ :creative_id, :channel_id ], unique: true
    add_index :slack_channel_links, :channel_id
  end
end
