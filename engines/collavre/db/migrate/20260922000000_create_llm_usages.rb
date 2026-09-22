class CreateLlmUsages < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :usage_attribution, :json, default: {}, null: false
    create_table :llm_usages do |t|
      t.string :event_key, null: false
      t.string :execution_id, null: false
      t.string :measurement, null: false, default: "call"
      t.string :vendor, null: false
      t.string :model, null: false
      t.bigint :agent_id
      t.bigint :owner_id
      t.bigint :requester_id
      t.string :requester_kind, null: false
      t.json :requester_ids, default: [], null: false
      t.json :source_comment_ids, default: [], null: false
      t.bigint :task_id
      t.bigint :creative_id
      t.bigint :topic_id
      t.bigint :activity_log_id
      t.bigint :input_tokens
      t.bigint :output_tokens
      t.bigint :cache_read_tokens
      t.bigint :cache_write_tokens
      t.json :raw_usage, default: {}, null: false
      t.integer :normalization_version, default: 1, null: false
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    create_table :llm_usage_requesters do |t|
      t.bigint :llm_usage_id, null: false
      t.bigint :user_id, null: false
    end
    add_index :llm_usage_requesters, [ :user_id, :llm_usage_id ], unique: true
    add_index :llm_usage_requesters, :llm_usage_id
    add_foreign_key :llm_usage_requesters, :llm_usages, on_delete: :cascade
    add_index :llm_usages, :event_key, unique: true
    add_index :llm_usages, :execution_id
    add_index :llm_usages, :task_id
    add_index :llm_usages, :occurred_at
    %i[owner_id requester_id agent_id].each do |column|
      add_index :llm_usages, [ column, :occurred_at ]
    end
  end
end
