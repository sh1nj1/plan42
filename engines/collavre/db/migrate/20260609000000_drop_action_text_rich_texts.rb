# Drops the dead ActionText table. Creatives moved their rich text to the
# `creatives.description` column (see 20251126040752_add_description_to_creatives),
# and no model declares `has_rich_text` anymore, so this table is unused.
class DropActionTextRichTexts < ActiveRecord::Migration[8.1]
  def up
    drop_table :action_text_rich_texts
  end

  def down
    create_table :action_text_rich_texts do |t|
      t.string :name, null: false
      t.text :body
      t.references :record, null: false, polymorphic: true, index: false

      t.timestamps

      t.index [ :record_type, :record_id, :name ], name: "index_action_text_rich_texts_uniqueness", unique: true
    end
  end
end
