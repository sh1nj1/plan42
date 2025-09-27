class AddActionExecutionTrackingToComments < ActiveRecord::Migration[8.0]
  def change
    add_column :comments, :action_executed_at, :datetime
    add_reference :comments, :action_executed_by, foreign_key: { to_table: :users }
  end
end
