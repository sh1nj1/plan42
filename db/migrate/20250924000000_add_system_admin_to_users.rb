class AddSystemAdminToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :system_admin, :boolean, null: false, default: false
    add_index :users, :system_admin
  end
end
