class AddLastTopicSaveFencesToUserCreativePreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :user_creative_preferences, :last_topic_save_fence_issued, :bigint, null: false, default: 0
    add_column :user_creative_preferences, :last_topic_save_fence_applied, :bigint, null: false, default: 0
  end
end
