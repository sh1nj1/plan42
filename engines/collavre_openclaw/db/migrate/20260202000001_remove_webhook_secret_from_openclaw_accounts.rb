class RemoveWebhookSecretFromOpenclawAccounts < ActiveRecord::Migration[8.0]
  def change
    remove_column :openclaw_accounts, :webhook_secret, :string
  end
end
