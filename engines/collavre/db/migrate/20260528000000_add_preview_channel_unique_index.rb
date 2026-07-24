class AddPreviewChannelUniqueIndex < ActiveRecord::Migration[8.1]
  def up
    postgres = connection.adapter_name == "PostgreSQL"

    # Mirror the PR-channel uniqueness guarantee for preview channels: a topic
    # has at most one PreviewChannel per worktree_id. Without this, a racing
    # preview_attach (e.g. concurrent CI + skill calls) could land two rows
    # for the same worktree and the chip would render twice. `type` is
    # included so the partial index does not collide with other channel
    # subtypes that happen to store a `worktree_id` in their config.
    if postgres
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_topic_preview_worktree
        ON channels (topic_id, (config->>'worktree_id'))
        WHERE type = 'Collavre::PreviewChannel'
      SQL
    else
      execute <<~SQL
        CREATE UNIQUE INDEX index_channels_on_topic_preview_worktree
        ON channels (topic_id, json_extract(config, '$.worktree_id'))
        WHERE type = 'Collavre::PreviewChannel'
      SQL
    end
  end

  def down
    if connection.index_exists?(:channels, nil, name: "index_channels_on_topic_preview_worktree")
      execute "DROP INDEX index_channels_on_topic_preview_worktree"
    end
  end
end
