class AddAgentConfToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :agent_conf, :text
  end
end
