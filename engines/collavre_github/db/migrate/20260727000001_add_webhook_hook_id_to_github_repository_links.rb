class AddWebhookHookIdToGithubRepositoryLinks < ActiveRecord::Migration[8.1]
  # The GitHub hook id that an instance of this app created for the repository.
  #
  # It is the only positive evidence that a hook found on GitHub belongs to a
  # deployment sharing THIS database: the id was written here by whichever
  # instance created it. Host or path similarity proves nothing — an unrelated
  # deployment can serve the very same path — and deferring to a hook that
  # feeds someone else's database would leave this instance receiving nothing.
  #
  # Stored on every link for the repository rather than only the primary one so
  # that deleting a link does not lose the registration and let the next
  # provisioning run create a second hook. This mirrors how `webhook_secret` is
  # already aligned across a repository's links.
  def change
    add_column :github_repository_links, :webhook_hook_id, :bigint
  end
end
