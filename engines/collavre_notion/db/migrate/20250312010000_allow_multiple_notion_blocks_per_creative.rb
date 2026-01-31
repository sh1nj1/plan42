class AllowMultipleNotionBlocksPerCreative < ActiveRecord::Migration[8.0]
  def change
    remove_index :notion_block_links, name: "index_notion_block_links_on_page_link_and_creative"
  end
end
