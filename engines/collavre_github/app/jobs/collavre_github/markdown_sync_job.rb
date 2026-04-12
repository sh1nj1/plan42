module CollavreGithub
  class MarkdownSyncJob < ApplicationJob
    queue_as :default

    def perform(repository_link_id, push_payload)
      link = CollavreGithub::RepositoryLink.find_by(id: repository_link_id)
      return unless link&.markdown_sync_enabled?

      CollavreGithub::MarkdownSync::IncrementalSyncService.new(
        repository_link: link,
        push_payload: push_payload
      ).call
    rescue StandardError => e
      Rails.logger.error("[MarkdownSync] Incremental sync failed for link #{repository_link_id}: #{e.message}")
      Rails.logger.error(e.backtrace&.first(10)&.join("\n"))
    end
  end
end
