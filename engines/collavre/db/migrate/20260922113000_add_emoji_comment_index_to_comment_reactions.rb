class AddEmojiCommentIndexToCommentReactions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :comment_reactions, [ :emoji, :comment_id ], algorithm: concurrent_algorithm
  end

  def down
    remove_index :comment_reactions, [ :emoji, :comment_id ], algorithm: concurrent_algorithm
  end

  private

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
