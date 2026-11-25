class AddExpansionSaveSequencesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :expansion_save_sequences, :json, null: false, default: {}
  end
end
