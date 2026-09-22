class AddExpansionSaveSequencesToUserCreativePreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :user_creative_preferences, :expansion_save_sequences, :json, null: false, default: {}
  end
end
