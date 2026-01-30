class AddCascadeDeleteToSlackCommentForeignKeys < ActiveRecord::Migration[8.0]
  def change
    # Remove existing foreign keys
    remove_foreign_key :slack_comment_links, :comments
    remove_foreign_key :slack_message_logs, :comments

    # Re-add with ON DELETE CASCADE
    add_foreign_key :slack_comment_links, :comments, on_delete: :cascade
    add_foreign_key :slack_message_logs, :comments, on_delete: :cascade
  end
end
