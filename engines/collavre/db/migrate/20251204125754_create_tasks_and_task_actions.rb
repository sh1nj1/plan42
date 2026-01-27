class CreateTasksAndTaskActions < ActiveRecord::Migration[8.0]
  def change
    create_table :tasks do |t|
      t.string :name
      t.string :status, default: "pending"
      t.string :trigger_event_name
      t.json :trigger_event_payload
      t.references :agent, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end

    create_table :task_actions do |t|
      t.references :task, null: false, foreign_key: true
      t.string :action_type
      t.json :payload
      t.string :status, default: "pending"
      t.json :result

      t.timestamps
    end
  end
end
