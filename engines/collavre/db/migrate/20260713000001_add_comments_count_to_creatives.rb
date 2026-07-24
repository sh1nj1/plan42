class AddCommentsCountToCreatives < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:creatives, :comments_count)
      add_column :creatives, :comments_count, :integer, default: 0, null: false
    end

    # Backfill: straight COUNT (no soft-delete on comments). Matches house
    # raw-SQL backfill convention.
    execute <<~SQL.squish
      UPDATE creatives
      SET comments_count = (
        SELECT COUNT(*) FROM comments WHERE comments.creative_id = creatives.id
      )
    SQL
  end

  def down
    remove_column :creatives, :comments_count if column_exists?(:creatives, :comments_count)
  end
end
