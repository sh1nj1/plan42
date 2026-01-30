class AddCommentIdToSlackMessageLogs < ActiveRecord::Migration[8.0]
  def change
    add_reference :slack_message_logs, :comment, foreign_key: { to_table: :comments }
  end
end
