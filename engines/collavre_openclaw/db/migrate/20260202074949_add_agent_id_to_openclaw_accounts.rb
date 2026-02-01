class AddAgentIdToOpenclawAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :openclaw_accounts, :agent_id, :string
    add_column :openclaw_accounts, :agent_provisioned_at, :datetime
  end
end
