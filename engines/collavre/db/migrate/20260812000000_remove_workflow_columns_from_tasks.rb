class RemoveWorkflowColumnsFromTasks < ActiveRecord::Migration[8.1]
  # The /work command and its WorkflowExecutor are gone, and they were the only
  # producers of parent_task_id / workflow_context / workflow_state / retry_count.
  # Nothing reads these columns anymore, so drop them.
  def up
    # Any workflow still mid-flight loses the state that would let it advance.
    # Cancel those rows before the columns disappear so they cannot linger as
    # permanently "running" tasks holding a topic slot.
    execute(<<~SQL.squish)
      UPDATE tasks
      SET status = 'cancelled'
      WHERE status IN ('pending', 'queued', 'running', 'delegated', 'pending_approval')
        AND (parent_task_id IS NOT NULL
             OR trigger_event_name IN ('work_command', 'workflow_subtask'))
    SQL

    remove_foreign_key :tasks, :tasks, column: :parent_task_id, if_exists: true
    remove_column :tasks, :parent_task_id, :integer
    remove_column :tasks, :workflow_context, :text
    remove_column :tasks, :workflow_state, :json
    remove_column :tasks, :retry_count, :integer, default: 0, null: false
  end

  def down
    add_column :tasks, :parent_task_id, :integer
    add_column :tasks, :workflow_context, :text
    add_column :tasks, :workflow_state, :json
    add_column :tasks, :retry_count, :integer, default: 0, null: false
    add_index :tasks, :parent_task_id
    add_foreign_key :tasks, :tasks, column: :parent_task_id, on_delete: :nullify
  end
end
