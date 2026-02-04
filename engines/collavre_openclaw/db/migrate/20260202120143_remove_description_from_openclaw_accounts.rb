class RemoveDescriptionFromOpenclawAccounts < ActiveRecord::Migration[8.1]
  def change
    remove_column :openclaw_accounts, :description, :text
  end
end
