class GithubRepositoryLink < ApplicationRecord
  belongs_to :creative
  belongs_to :github_account

  validates :repository_full_name, presence: true
end
