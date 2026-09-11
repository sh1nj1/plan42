class AddLastTopicSaveSequencesToUserCreativePreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :user_creative_preferences, :last_topic_save_sequences, :json, null: false, default: {}
  end
end
