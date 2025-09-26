class CreateGithubIntegrations < ActiveRecord::Migration[8.0]
  def change
    create_table :github_accounts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :github_uid, null: false
      t.string :login, null: false
      t.string :name
      t.string :avatar_url
      t.string :token, null: false
      t.datetime :token_expires_at
      t.timestamps
    end

    create_table :github_repository_links do |t|
      t.references :creative, null: false, foreign_key: true
      t.references :github_account, null: false, foreign_key: true
      t.bigint :repository_id
      t.string :repository_full_name, null: false
      t.timestamps
    end

    add_index :github_accounts, :github_uid, unique: true
    add_index :github_repository_links, :repository_full_name
    add_index :github_repository_links, [ :creative_id, :repository_full_name ], unique: true, name: "index_github_links_on_creative_and_repo"
  end
end
