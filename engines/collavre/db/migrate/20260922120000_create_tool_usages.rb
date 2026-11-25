class CreateToolUsages < ActiveRecord::Migration[8.0]
  def change
    create_table :tool_usages do |t|
      t.string :event_key, null: false
      t.string :execution_id, null: false
      t.string :source, null: false
      t.string :tool_name, null: false
      t.boolean :succeeded, null: false, default: true
      t.integer :duration_ms
      t.bigint :agent_id
      t.bigint :owner_id
      t.bigint :requester_id
      t.string :requester_kind, null: false
      t.json :requester_ids, default: [], null: false
      t.json :source_comment_ids, default: [], null: false
      t.bigint :task_id
      t.bigint :creative_id
      t.bigint :topic_id
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    create_table :tool_usage_requesters do |t|
      t.bigint :tool_usage_id, null: false
      t.bigint :user_id, null: false
    end
    add_index :tool_usage_requesters, [ :user_id, :tool_usage_id ], unique: true
    add_index :tool_usage_requesters, :tool_usage_id
    add_foreign_key :tool_usage_requesters, :tool_usages, on_delete: :cascade
    add_index :tool_usages, :event_key, unique: true
    add_index :tool_usages, :execution_id
    add_index :tool_usages, :task_id
    add_index :tool_usages, [ :tool_name, :occurred_at ]
    %i[owner_id requester_id agent_id].each do |column|
      add_index :tool_usages, [ column, :occurred_at ]
    end
  end
end
