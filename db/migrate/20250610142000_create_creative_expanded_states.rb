class CreateCreativeExpandedStates < ActiveRecord::Migration[8.0]
  def change
    create_table :creative_expanded_states do |t|
      t.references :creative, null: true, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.json :expanded_status, null: false, default: {}
      t.timestamps
    end
    add_index :creative_expanded_states, [ :creative_id, :user_id ], unique: true
  end
end
