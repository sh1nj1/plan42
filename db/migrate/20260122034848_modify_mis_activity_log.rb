class ModifyMisActivityLog < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :mis_activity_log, :users
    add_column :mis_activity_log, :user_name, :string
  end
end
