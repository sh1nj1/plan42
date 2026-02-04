class AddPendingToolCallToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :pending_tool_call, :json
  end
end
