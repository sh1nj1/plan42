class AddWebhookSecretToGithubRepositoryLinks < ActiveRecord::Migration[8.0]
  class GithubRepositoryLink < ApplicationRecord
    self.table_name = "github_repository_links"
  end

  def up
    add_column :github_repository_links, :webhook_secret, :string

    GithubRepositoryLink.reset_column_information

    say_with_time "Backfilling webhook secrets" do
      GithubRepositoryLink.find_each do |link|
        link.update_columns(webhook_secret: generate_secret)
      end
    end

    change_column_null :github_repository_links, :webhook_secret, false
  end

  def down
    remove_column :github_repository_links, :webhook_secret
  end

  private

  def generate_secret
    SecureRandom.hex(20)
  end
end
