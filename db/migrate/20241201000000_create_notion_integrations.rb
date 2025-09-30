class CreateNotionIntegrations < ActiveRecord::Migration[8.0]
  def change
    create_table :notion_accounts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :notion_uid, null: false
      t.string :workspace_name
      t.string :workspace_id
      t.string :bot_id
      t.string :token, null: false
      t.datetime :token_expires_at
      t.timestamps
    end

    create_table :notion_page_links do |t|
      t.references :creative, null: false, foreign_key: true
      t.references :notion_account, null: false, foreign_key: true
      t.string :page_id, null: false
      t.string :page_title
      t.string :page_url
      t.string :parent_page_id
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :notion_accounts, :notion_uid, unique: true
    add_index :notion_page_links, :page_id, unique: true
    add_index :notion_page_links, [ :creative_id, :page_id ], unique: true, name: "index_notion_links_on_creative_and_page"
  end
end
