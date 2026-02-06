class AddTopicIdToTasks < ActiveRecord::Migration[8.0]
  def change
    add_column :tasks, :topic_id, :integer, null: true
    add_index :tasks, [ :topic_id, :status ]
  end
end
