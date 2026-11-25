# frozen_string_literal: true

class AddAsyncApprovalTaskToComments < ActiveRecord::Migration[8.0]
  def up
    add_column :comments, :async_approval_task_id, :bigint
    add_index :comments, :async_approval_task_id

    comments = Class.new(ActiveRecord::Base) { self.table_name = "comments" }
    comments.reset_column_information
    comments.where("action LIKE ?", "%approval_gate%").find_each do |comment|
      payload = JSON.parse(comment.action) rescue nil
      next unless payload.is_a?(Hash) && payload["action"] == "approval_gate" && payload["mode"] == "async"

      comment.update_columns(async_approval_task_id: payload["task_id"])
    end
  end

  def down
    remove_index :comments, :async_approval_task_id
    remove_column :comments, :async_approval_task_id
  end
end
