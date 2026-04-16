class AddMarkdownSyncToRepositoryLinks < ActiveRecord::Migration[8.0]
  def change
    add_column :github_repository_links, :markdown_sync_enabled, :boolean, default: false, null: false
    add_column :github_repository_links, :markdown_root_creative_id, :integer
    add_column :github_repository_links, :last_synced_at, :datetime
    add_column :github_repository_links, :sync_branch, :string

    add_index :github_repository_links, :markdown_sync_enabled
  end
end
