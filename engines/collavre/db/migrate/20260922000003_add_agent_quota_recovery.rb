class AddAgentQuotaRecovery < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :quota_blocked_until, :datetime
    add_column :users, :quota_retry_count, :integer, default: 0, null: false
    add_column :users, :quota_retry_exhausted, :boolean, default: false, null: false
  end
end
