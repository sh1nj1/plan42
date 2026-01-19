class PopulateOwnerCacheEntries < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Populating owner cache entries" do
      # Insert owner entries for all creatives (admin = 4)
      # Use INSERT ... ON CONFLICT to avoid duplicates
      # datetime('now') for SQLite compatibility
      execute <<~SQL
        INSERT INTO creative_shares_caches (creative_id, user_id, permission, source_share_id, created_at, updated_at)
        SELECT id, user_id, 4, NULL, datetime('now'), datetime('now')
        FROM creatives
        WHERE user_id IS NOT NULL
        ON CONFLICT (creative_id, user_id) DO NOTHING
      SQL
    end
  end

  def down
    say_with_time "Removing owner cache entries" do
      execute <<~SQL
        DELETE FROM creative_shares_caches
        WHERE source_share_id IS NULL
      SQL
    end
  end
end
