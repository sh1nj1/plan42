class AddLastTopicAllMessagesToUserCreativePreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :user_creative_preferences, :last_topic_all_messages, :boolean, null: false, default: false
  end
end
