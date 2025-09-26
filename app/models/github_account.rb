class GithubAccount < ApplicationRecord
  belongs_to :user
  has_many :github_repository_links, dependent: :destroy

  validates :github_uid, :login, :token, presence: true
  validates :github_uid, uniqueness: true

  def expired?
    token_expires_at.present? && token_expires_at < Time.current
  end
end
