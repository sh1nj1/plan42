# frozen_string_literal: true

class CreateRetiredTaskExecutions < ActiveRecord::Migration[8.0]
  def change
    create_table :retired_task_executions do |t|
      t.string :execution_job_id, null: false
      t.timestamps
    end
    add_index :retired_task_executions, :execution_job_id, unique: true
  end
end
