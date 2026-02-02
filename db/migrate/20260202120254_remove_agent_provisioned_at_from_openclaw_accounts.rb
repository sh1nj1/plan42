class RemoveAgentProvisionedAtFromOpenclawAccounts < ActiveRecord::Migration[8.1]
  def change
    remove_column :openclaw_accounts, :agent_provisioned_at, :datetime
  end
end
