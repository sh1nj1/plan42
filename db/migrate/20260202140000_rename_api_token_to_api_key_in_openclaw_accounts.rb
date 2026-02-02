class RenameApiTokenToApiKeyInOpenclawAccounts < ActiveRecord::Migration[7.2]
  def change
    rename_column :openclaw_accounts, :api_token, :api_key
  end
end
