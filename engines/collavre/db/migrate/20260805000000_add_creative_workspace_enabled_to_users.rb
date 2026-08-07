class AddCreativeWorkspaceEnabledToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :creative_workspace_enabled, :boolean, default: false, null: false
  end
end
