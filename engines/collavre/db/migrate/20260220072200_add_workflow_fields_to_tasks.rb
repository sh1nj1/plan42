class AddWorkflowFieldsToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :parent_task_id, :integer
    add_index :tasks, :parent_task_id
    add_column :tasks, :workflow_context, :text
    add_column :tasks, :workflow_state, :json
    add_column :tasks, :creative_id, :integer
    add_index :tasks, :creative_id
  end
end
