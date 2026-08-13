class AddLastTopicRevisionToUserCreativePreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :user_creative_preferences, :last_topic_revision, :integer, null: false, default: 0
  end
end
