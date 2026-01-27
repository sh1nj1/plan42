module Collavre
  class GithubAccount < ApplicationRecord
    self.table_name = "github_accounts"

    belongs_to :user, class_name: "Collavre::User"
    has_many :github_repository_links, class_name: "Collavre::GithubRepositoryLink", dependent: :destroy

    encrypts :token, deterministic: false
  end
end
