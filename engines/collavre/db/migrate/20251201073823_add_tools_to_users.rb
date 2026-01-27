class AddToolsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :tools, :json
  end
end
