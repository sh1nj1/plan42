class PromoteChannelConfigIndexColumns < ActiveRecord::Migration[8.1]
  # The channels uniqueness guarantees were enforced by UNIQUE indexes over
  # JSON expressions: `json_extract(config, '$.repo_full_name')` on SQLite and
  # `config->>'repo_full_name'` on PostgreSQL. Those expressions serialize
  # differently per adapter, so schema.rb (dumped from the SQLite dev DB)
  # carries json_extract, which is not a PostgreSQL function -- `db:schema:load`
  # on PostgreSQL crashes. Promote the extracted keys to real columns kept in
  # sync from `config` (see Collavre::Channel#sync_indexed_config_columns) and
  # replace the expression indexes with plain-column indexes that dump
  # identically on both adapters.
  def up
    postgres = connection.adapter_name == "PostgreSQL"

    add_column :channels, :repo_full_name, :string
    add_column :channels, :pr_number, :integer
    add_column :channels, :worktree_id, :string

    if postgres
      execute <<~SQL.squish
        UPDATE channels SET
          repo_full_name = config->>'repo_full_name',
          pr_number = NULLIF(config->>'pr_number', '')::integer,
          worktree_id = config->>'worktree_id'
      SQL
    else
      execute <<~SQL.squish
        UPDATE channels SET
          repo_full_name = json_extract(config, '$.repo_full_name'),
          pr_number = json_extract(config, '$.pr_number'),
          worktree_id = json_extract(config, '$.worktree_id')
      SQL
    end

    remove_index :channels, name: "index_channels_on_type_topic_repo_pr"
    remove_index :channels, name: "index_channels_on_topic_preview_worktree"

    add_index :channels, [ :type, :topic_id, :repo_full_name, :pr_number ],
              unique: true, name: "index_channels_on_type_topic_repo_pr"
    add_index :channels, [ :topic_id, :worktree_id ],
              unique: true, name: "index_channels_on_topic_preview_worktree",
              where: "type = 'Collavre::PreviewChannel'"
  end

  def down
    postgres = connection.adapter_name == "PostgreSQL"

    remove_index :channels, name: "index_channels_on_type_topic_repo_pr"
    remove_index :channels, name: "index_channels_on_topic_preview_worktree"

    remove_column :channels, :repo_full_name
    remove_column :channels, :pr_number
    remove_column :channels, :worktree_id

    if postgres
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_type_topic_repo_pr
        ON channels (type, topic_id, (config->>'repo_full_name'), (config->>'pr_number'))
      SQL
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_topic_preview_worktree
        ON channels (topic_id, (config->>'worktree_id'))
        WHERE type = 'Collavre::PreviewChannel'
      SQL
    else
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_type_topic_repo_pr
        ON channels (type, topic_id, json_extract(config, '$.repo_full_name'), json_extract(config, '$.pr_number'))
      SQL
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_topic_preview_worktree
        ON channels (topic_id, json_extract(config, '$.worktree_id'))
        WHERE type = 'Collavre::PreviewChannel'
      SQL
    end
  end
end
