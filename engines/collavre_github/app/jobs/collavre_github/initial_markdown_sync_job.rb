module CollavreGithub
  class InitialMarkdownSyncJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(repository_link_id)
      link = CollavreGithub::RepositoryLink.find_by(id: repository_link_id)
      return unless link&.markdown_sync_enabled?

      user = link.creative.user
      return unless user

      CollavreGithub::MarkdownSync::InitialImportService.new(
        repository_link: link,
        user: user
      ).call
    end
  end
end
