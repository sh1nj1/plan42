# frozen_string_literal: true

class AddReservedToWorkflowExecutions < ActiveRecord::Migration[8.0]
  def change
    add_column :workflow_executions, :reserved, :boolean, null: false, default: false
  end
end
