class AddQuotedCreativeToComments < ActiveRecord::Migration[8.0]
  QUOTE_TARGET_CONSTRAINT = "comments_single_quote_target"

  def change
    add_column :comments, :quoted_creative_id, :integer
    add_index :comments, :quoted_creative_id
    add_check_constraint :comments, "quoted_comment_id IS NULL OR quoted_creative_id IS NULL",
                         name: QUOTE_TARGET_CONSTRAINT
  end
end
