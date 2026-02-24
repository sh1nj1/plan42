class AddUndoneAtToMisActivityLog < ActiveRecord::Migration[8.1]
  def change
    add_column :mis_activity_log, :undone_at, :datetime, null: true
  end
end
