class AddRepositoryIdIndexToGithubRepositoryLinks < ActiveRecord::Migration[8.1]
  # The column has existed since the engine's first migration but was never
  # written or read. Webhook routing now matches on it (it is the only
  # repository identifier that survives a rename), so it needs an index.
  #
  # Not unique: one repository is deliberately linked to many creatives.
  def change
    add_index :github_repository_links, :repository_id
  end
end
