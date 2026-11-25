class AddSystemAgentToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :system_agent, :boolean, default: false, null: false
  end
end
