class AddMarkdownRootCreativeIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :github_repository_links, :markdown_root_creative_id, where: "markdown_root_creative_id IS NOT NULL", if_not_exists: true
  end
end
