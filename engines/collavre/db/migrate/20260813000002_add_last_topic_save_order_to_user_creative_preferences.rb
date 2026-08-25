class AddLastTopicSaveOrderToUserCreativePreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :user_creative_preferences, :last_topic_save_session_id, :string
    add_column :user_creative_preferences, :last_topic_save_sequence, :integer
  end
end
