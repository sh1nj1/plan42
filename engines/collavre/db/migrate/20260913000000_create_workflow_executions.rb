# frozen_string_literal: true

class CreateWorkflowExecutions < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_chains do |t|
      t.string :correlation_id, null: false
      t.bigint :creative_id, null: false
      t.bigint :topic_id, null: false, default: 0
      t.integer :root_depth, null: false
      t.integer :task_count, null: false, default: 0
      t.integer :step_count, null: false, default: 0
      t.timestamps
    end
    add_index :workflow_chains, [ :correlation_id, :creative_id, :topic_id ], unique: true, name: :workflow_chain_identity
    create_table :workflow_executions do |t|
      t.references :chain, null: false, foreign_key: { to_table: :workflow_chains }
      t.string :input_event_id, null: false
      t.bigint :rule_id, null: false
      t.json :rule_snapshot, null: false
      t.json :context, null: false
      t.json :selected_agent_ids, null: false, default: []
      t.json :decisions, null: false, default: []
      t.bigint :owner_id
      t.string :reason
      t.datetime :sealed_at
      t.timestamps
    end
    add_index :workflow_executions, [ :chain_id, :input_event_id ], unique: true, name: :workflow_execution_identity
    add_index :workflow_executions, [ :chain_id, :rule_id ]
    add_index :workflow_executions, :sealed_at
    create_table :workflow_outboxes do |t|
      t.references :execution, null: false, foreign_key: { to_table: :workflow_executions }
      t.string :key, null: false
      t.bigint :agent_id
      t.json :context, null: false
      t.datetime :due_at, null: false
      t.string :state, null: false, default: 'pending'
      t.string :reason
      t.integer :attempts, null: false, default: 0
      t.string :claim_token
      t.datetime :claimed_at
      t.bigint :reply_comment_id
      t.timestamps
    end
    add_index :workflow_outboxes, [ :execution_id, :key ], unique: true
    add_index :workflow_outboxes, [ :state, :due_at, :claimed_at ]
    create_table :workflow_receipts do |t|
      t.string :source, null: false
      t.string :event_name, null: false
      t.string :job_id, null: false
      t.references :execution, null: false, foreign_key: { to_table: :workflow_executions }
      t.timestamps
    end
    add_index :workflow_receipts, [ :source, :event_name, :job_id ], unique: true, name: :workflow_receipt_identity
    add_reference :tasks, :workflow_execution, null: true, foreign_key: { to_table: :workflow_executions }
    add_column :tasks, :workflow_stop_reason, :string
    add_index :tasks, [ :workflow_execution_id, :agent_id ], unique: true, name: :workflow_task_identity
    add_reference :comment_notification_deliveries, :workflow_execution, null: true, foreign_key: { to_table: :workflow_executions }
    add_column :comment_notification_deliveries, :title, :text
    add_column :comment_notification_deliveries, :push_attempts, :integer
    add_column :comment_notification_deliveries, :push_state, :string
    add_index :comment_notification_deliveries, [ :push_state, :push_claimed_at ], name: :workflow_push_recovery
  end
end
