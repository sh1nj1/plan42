class AddRepositoryIdIndexToGithubRepositoryLinks < ActiveRecord::Migration[8.1]
  # The column has existed since the engine's first migration but was never
  # written or read. Webhook routing now matches on it (it is the only
  # repository identifier that survives a rename), so it needs an index.
  # `webhook_hook_id` is also used as a request-time fallback for links that
  # have not received a repository id yet, and must not require a table scan.
  #
  # Not unique: one repository is deliberately linked to many creatives.
  def change
    add_index :github_repository_links, :repository_id
    add_index :github_repository_links, :webhook_hook_id
  end
end
