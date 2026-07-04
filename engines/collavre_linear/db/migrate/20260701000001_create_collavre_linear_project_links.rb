class CreateCollavreLinearProjectLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :linear_project_links do |t|
      t.references :creative, null: false, foreign_key: { to_table: :creatives }
      t.references :account, null: false, foreign_key: { to_table: :linear_accounts }
      t.string :linear_project_id, null: false
      t.string :team_id, null: false
      # Encrypted at rest (ActiveRecord encryption); the envelope can exceed the
      # 255-byte `string` limit in PostgreSQL, so store it in a `text` column.
      t.text :webhook_secret, null: false
      t.integer :sync_state, null: false, default: 0
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :linear_project_links, [ :creative_id, :linear_project_id ], unique: true, name: "index_linear_project_links_on_creative_and_project"
  end
end
