class AddEmojiCommentIndexToCommentReactions < ActiveRecord::Migration[8.1]
  def change
    add_index :comment_reactions, [ :emoji, :comment_id ]
  end
end
