class CreateInboxItems < ActiveRecord::Migration[8.0]
  def change
    create_table :inbox_items do |t|
      t.text :message
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :link
      t.string :state, default: "new", null: false

      t.timestamps
    end

    add_index :inbox_items, :state
  end
end
