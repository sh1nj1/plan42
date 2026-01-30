class RemoveIsActiveFromSlackChannelLinks < ActiveRecord::Migration[8.0]
  def change
    remove_column :slack_channel_links, :is_active, :boolean, default: true, null: false
  end
end
