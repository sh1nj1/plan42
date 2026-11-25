class CreateNotionPageNodes < ActiveRecord::Migration[8.0]
  def change
    create_table :notion_page_nodes do |t|
      t.references :notion_page_link, null: false, foreign_key: true
      # Keep the source ID after hard deletion so the next sync can archive the page.
      t.bigint :creative_id, null: false
      t.string :page_id, null: false
      t.string :parent_page_id, null: false
      t.string :content_hash
      t.json :body_block_ids, null: false, default: []
      t.timestamps
    end
    add_index :notion_page_nodes, [ :notion_page_link_id, :creative_id ], unique: true, name: "index_notion_nodes_on_export_and_creative"
    add_index :notion_page_nodes, :page_id, unique: true
  end
end
