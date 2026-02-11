class AddQuotedCommentToComments < ActiveRecord::Migration[8.0]
  def change
    add_column :comments, :quoted_comment_id, :integer
    add_column :comments, :quoted_text, :text
    add_index :comments, :quoted_comment_id
  end
end
