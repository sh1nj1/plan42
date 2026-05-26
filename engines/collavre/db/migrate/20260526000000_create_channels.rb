class CreateChannels < ActiveRecord::Migration[8.1]
  def up
    postgres = connection.adapter_name == "PostgreSQL"

    create_table :channels do |t|
      t.string :type, null: false
      t.references :topic, null: false, foreign_key: { to_table: :topics }, index: true
      if postgres
        t.jsonb :config, null: false, default: {}
      else
        t.json :config, null: false, default: {}
      end
      t.integer :state, null: false, default: 0
      t.string :latest_label
      t.string :latest_link
      t.datetime :last_event_at
      t.timestamps
    end

    if postgres
      add_index :channels, :config, using: :gin
      add_index :channels, :type
      # Concurrent webhook safety: a single PR may emit pull_request.opened twice
      # back-to-back (or auto-attach can race with pr_monitor). Without this
      # constraint, the dispatch loop would inject every event N times.
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_type_topic_repo_pr
        ON channels (type, topic_id, (config->>'repo_full_name'), (config->>'pr_number'))
      SQL
    else
      add_index :channels, :type
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_type_topic_repo_pr
        ON channels (type, topic_id, json_extract(config, '$.repo_full_name'), json_extract(config, '$.pr_number'))
      SQL
    end
  end

  def down
    drop_table :channels
  end
end
