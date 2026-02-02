class RemoveAgentIdFromOpenclawAccounts < ActiveRecord::Migration[7.2]
  def change
    remove_column :openclaw_accounts, :agent_id, :string
  end
end
