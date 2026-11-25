class DetachRetiredIntegrations < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :notion_accounts, :users, if_exists: true
    remove_foreign_key :linear_accounts, :users, if_exists: true
    remove_foreign_key :notion_page_links, :creatives, if_exists: true
    remove_foreign_key :notion_block_links, :creatives, if_exists: true
    remove_foreign_key :linear_project_links, :creatives, if_exists: true
    remove_foreign_key :linear_issue_links, :creatives, if_exists: true
  end
end
