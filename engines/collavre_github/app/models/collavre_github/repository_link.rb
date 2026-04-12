module CollavreGithub
  class RepositoryLink < ApplicationRecord
    self.table_name = "github_repository_links"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :github_account, class_name: "CollavreGithub::Account"
    belongs_to :markdown_root_creative, class_name: "Collavre::Creative", optional: true

    validates :repository_full_name, presence: true
    validates :webhook_secret, presence: true

    before_validation :ensure_webhook_secret

    scope :markdown_sync, -> { where(markdown_sync_enabled: true) }

    def markdown_sync_branch
      sync_branch.presence || "main"
    end

    private

    def ensure_webhook_secret
      self.webhook_secret ||= SecureRandom.hex(20)
    end
  end
end
