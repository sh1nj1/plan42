class AddLastSyncedAtToSlackChannelLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :slack_channel_links, :last_synced_at, :datetime
  end
end
