class CreateMisActivityLog < ActiveRecord::Migration[8.1]
  def change
    create_table :mis_activity_log do |t|
      t.references :user, null: false, foreign_key: true
      t.string :action
      t.string :target_type
      t.string :target_id
      t.text :message
      t.json :metadata

      t.timestamps
    end
  end
end
