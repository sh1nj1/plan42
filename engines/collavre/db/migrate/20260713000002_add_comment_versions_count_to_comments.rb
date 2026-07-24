class AddCommentVersionsCountToComments < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:comments, :comment_versions_count)
      add_column :comments, :comment_versions_count, :integer, default: 0, null: false
    end

    # Backfill counts only the owning :comment association (comment_id),
    # NOT review_comment_id (review_versions).
    execute <<~SQL.squish
      UPDATE comments
      SET comment_versions_count = (
        SELECT COUNT(*) FROM comment_versions WHERE comment_versions.comment_id = comments.id
      )
    SQL
  end

  def down
    remove_column :comments, :comment_versions_count if column_exists?(:comments, :comment_versions_count)
  end
end
