module CollavreGithub
  class InitialMarkdownSyncJob < ApplicationJob
    queue_as :default

    def perform(repository_link_id)
      link = CollavreGithub::RepositoryLink.find_by(id: repository_link_id)
      return unless link&.markdown_sync_enabled?

      user = link.creative.user
      return unless user

      CollavreGithub::MarkdownSync::InitialImportService.new(
        repository_link: link,
        user: user
      ).call
    rescue StandardError => e
      Rails.logger.error("[MarkdownSync] Initial import failed for link #{repository_link_id}: #{e.message}")
      Rails.logger.error(e.backtrace&.first(10)&.join("\n"))
    end
  end
end
