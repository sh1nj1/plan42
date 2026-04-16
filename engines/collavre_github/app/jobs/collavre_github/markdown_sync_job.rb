module CollavreGithub
  class MarkdownSyncJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(repository_link_id, push_payload)
      link = CollavreGithub::RepositoryLink.find_by(id: repository_link_id)
      return unless link&.markdown_sync_enabled?

      CollavreGithub::MarkdownSync::IncrementalSyncService.new(
        repository_link: link,
        push_payload: push_payload
      ).call
    end
  end
end
