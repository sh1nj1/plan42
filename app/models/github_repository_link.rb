class GithubRepositoryLink < ApplicationRecord
  belongs_to :creative
  belongs_to :github_account

  validates :repository_full_name, presence: true
  validates :webhook_secret, presence: true

  before_validation :ensure_webhook_secret

  private

  def ensure_webhook_secret
    self.webhook_secret ||= SecureRandom.hex(20)
  end
end
