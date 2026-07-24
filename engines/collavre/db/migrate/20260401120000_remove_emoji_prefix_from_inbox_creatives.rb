class RemoveEmojiPrefixFromInboxCreatives < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      UPDATE creatives
      SET description = 'Inbox'
      WHERE data->>'kind' = 'inbox'
        AND description LIKE '📥%'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE creatives
      SET description = '📥 Inbox'
      WHERE data->>'kind' = 'inbox'
        AND description = 'Inbox'
    SQL
  end
end
