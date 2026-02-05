module CollavreGithub
  class Account < ApplicationRecord
    self.table_name = "github_accounts"

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    has_many :repository_links, class_name: "CollavreGithub::RepositoryLink",
             foreign_key: :github_account_id, dependent: :destroy

    encrypts :token, deterministic: false
  end
end
