class DropInboxItems < ActiveRecord::Migration[8.0]
  def up
    drop_table :inbox_items
  end

  def down
    create_table :inbox_items do |t|
      t.references :comment, foreign_key: { on_delete: :nullify }
      t.references :creative, foreign_key: { on_delete: :nullify }
      t.text :message
      t.string :message_key
      t.jsonb :message_params, default: {}, null: false
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.string :link
      t.string :state, default: "new", null: false

      t.timestamps
    end

    add_index :inbox_items, :state
  end
end
