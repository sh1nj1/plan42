class AddRequiresApprovalToMcpTools < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_tools, :requires_approval, :boolean, default: false, null: false
  end
end
