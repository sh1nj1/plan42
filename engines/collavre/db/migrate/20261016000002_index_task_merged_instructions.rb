# frozen_string_literal: true

class IndexTaskMergedInstructions < ActiveRecord::Migration[8.0]
  class Task < ActiveRecord::Base
    self.table_name = "tasks"
  end

  def up
    create_table :task_merged_instructions do |t|
      t.bigint :task_id, null: false
      t.bigint :comment_id, null: false
      t.index [ :comment_id, :task_id ], unique: true
      t.index :task_id
    end
    Task.find_each do |task|
      Array(task.trigger_event_payload&.fetch("merged_comment_ids", nil)).map(&:to_i).select(&:positive?).uniq.each do |id|
        execute "INSERT INTO task_merged_instructions (task_id, comment_id) VALUES (#{task.id.to_i}, #{id})"
      end
    end
  end

  def down
    drop_table :task_merged_instructions
  end
end
