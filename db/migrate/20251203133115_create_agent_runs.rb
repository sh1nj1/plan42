class CreateAgentRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_runs do |t|
      t.integer :creative_id, null: false
      t.integer :ai_user_id, null: false
      t.text :goal
      t.string :state, default: "planning"
      t.jsonb :context, default: {}
      t.jsonb :transcript, default: []
      t.integer :iteration_count, default: 0
      t.datetime :next_run_at
      t.string :status, default: "pending"

      t.timestamps
    end
    add_index :agent_runs, :creative_id
    add_index :agent_runs, :ai_user_id

    create_table :agent_actions do |t|
      t.integer :agent_run_id, null: false
      t.string :tool_name
      t.jsonb :arguments, default: {}
      t.text :result
      t.string :status, default: "pending"

      t.timestamps
    end
    add_index :agent_actions, :agent_run_id
  end
end
