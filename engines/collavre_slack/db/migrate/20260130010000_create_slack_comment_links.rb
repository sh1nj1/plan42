class CreateSlackCommentLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :slack_comment_links do |t|
      t.references :comment, null: false, foreign_key: { to_table: :comments }
      t.references :slack_channel_link, null: false, foreign_key: true
      t.string :message_ts, null: false

      t.timestamps
    end

    add_index :slack_comment_links, [:slack_channel_link_id, :message_ts], unique: true, name: "idx_slack_comment_links_on_channel_and_ts"
  end
end
