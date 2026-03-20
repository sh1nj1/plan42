class RenameCreativeExpandedStatesToUserCreativePreferences < ActiveRecord::Migration[8.0]
  def change
    rename_table :creative_expanded_states, :user_creative_preferences
    add_reference :user_creative_preferences, :last_topic, foreign_key: { to_table: :topics }, null: true
  end
end
