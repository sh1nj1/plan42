module Collavre
  class GithubRepositoryLink < ApplicationRecord
    self.table_name = "github_repository_links"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :github_account, class_name: "Collavre::GithubAccount"

    validates :repository_full_name, presence: true
    validates :webhook_secret, presence: true

    before_validation :ensure_webhook_secret

    private

    def ensure_webhook_secret
      self.webhook_secret ||= SecureRandom.hex(20)
    end
  end
end
