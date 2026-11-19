# frozen_string_literal: true

class AddTriggerCommentIdToTasks < ActiveRecord::Migration[8.0]
  class Task < ActiveRecord::Base
    self.table_name = "tasks"
  end

  def up
    add_column :tasks, :trigger_comment_id, :bigint
    add_index :tasks, :trigger_comment_id
    Task.reset_column_information
    Task.find_each do |task|
      value = task.trigger_event_payload&.dig("comment", "id")
      task.update_columns(trigger_comment_id: value.to_i) if value.to_s.match?(/\A[1-9]\d*\z/)
    end
  end

  def down
    remove_column :tasks, :trigger_comment_id
  end
end
