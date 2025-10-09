class CreateNotionBlockLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :notion_block_links do |t|
      t.references :notion_page_link, null: false, foreign_key: true, index: false
      t.references :creative, null: false, foreign_key: true, index: false
      t.string :block_id, null: false
      t.string :content_hash
      t.timestamps
    end

    add_index :notion_block_links, :notion_page_link_id, name: "index_notion_block_links_on_notion_page_link_id"
    add_index :notion_block_links, :creative_id
    add_index :notion_block_links, [:notion_page_link_id, :creative_id], unique: true, name: "index_notion_block_links_on_page_link_and_creative"
    add_index :notion_block_links, [:notion_page_link_id, :block_id], unique: true, name: "index_notion_block_links_on_page_link_and_block"
  end
end
