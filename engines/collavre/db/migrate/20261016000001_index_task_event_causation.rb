# frozen_string_literal: true

class IndexTaskEventCausation < ActiveRecord::Migration[8.0]
  class Task < ActiveRecord::Base
    self.table_name = "tasks"
  end

  def up
    add_column :tasks, :event_causation_id, :string
    add_index :tasks, :event_causation_id
    Task.reset_column_information
    Task.find_each do |task|
      task.update_columns(event_causation_id: task.trigger_event_payload&.dig("event", "causation_id"))
    end
  end

  def down
    remove_column :tasks, :event_causation_id
  end
end
