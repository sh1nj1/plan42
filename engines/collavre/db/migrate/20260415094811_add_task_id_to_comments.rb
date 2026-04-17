class AddTaskIdToComments < ActiveRecord::Migration[8.1]
  def change
    add_column :comments, :task_id, :integer
    add_index :comments, :task_id
  end
end
