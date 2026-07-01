class CreateCollavreLinearIssueLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :linear_issue_links do |t|
      t.references :creative, null: false, foreign_key: { to_table: :creatives }
      t.references :project_link, null: false, foreign_key: { to_table: :linear_project_links }
      t.string :linear_issue_id, null: false
      t.string :parent_issue_id
      t.integer :local_version, null: false, default: 0
      t.datetime :remote_updated_at
      t.string :content_hash
      t.integer :sync_state, null: false, default: 0
      t.timestamps
    end

    add_index :linear_issue_links, :creative_id, unique: true
    add_index :linear_issue_links, :linear_issue_id, unique: true
  end
end
