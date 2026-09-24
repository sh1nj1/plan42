# frozen_string_literal: true

class AddAsyncApprovalRecoveryToComments < ActiveRecord::Migration[8.0]
  def up
    add_column :comments, :async_approval_recovery_pending, :boolean, default: false, null: false
    add_index :comments, :async_approval_recovery_pending,
              name: "index_comments_on_pending_async_approval"

    # Existing decisions need one recovery pass after deployment.
    comments = Class.new(ActiveRecord::Base) { self.table_name = "comments" }
    comments.reset_column_information
    comments.where.not(action_executed_at: nil).where("action LIKE ?", "%approval_gate%").find_each do |comment|
      payload = JSON.parse(comment.action) rescue nil
      next unless payload.is_a?(Hash) && payload["mode"] == "async" && payload["decision"]

      comment.update_columns(async_approval_recovery_pending: true)
    end
  end

  def down
    remove_index :comments, name: "index_comments_on_pending_async_approval"
    remove_column :comments, :async_approval_recovery_pending
  end
end
