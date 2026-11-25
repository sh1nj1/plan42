# frozen_string_literal: true

class AddSuspensionToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :suspend_reason, :string
    add_column :tasks, :suspended_at, :datetime
    add_column :tasks, :suspended_from, :string
    add_column :tasks, :resume_not_before, :datetime
    add_column :tasks, :resume_count, :integer, null: false, default: 0
    add_index :tasks, %i[status resume_not_before]
  end
end
