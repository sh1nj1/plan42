class AddAgentQuotaProbe < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :quota_probe_task_id, :bigint
    add_column :users, :quota_probe_generation, :string
  end
end
