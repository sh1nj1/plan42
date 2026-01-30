class CreateSlackMessageLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :slack_message_logs do |t|
      t.references :slack_channel_link, null: false, foreign_key: { to_table: :slack_channel_links }
      t.references :sender, null: true, foreign_key: { to_table: :users }
      t.text :message, null: false
      t.string :message_ts
      t.string :status, null: false, default: "queued"
      t.text :error_message

      t.timestamps
    end
  end
end
