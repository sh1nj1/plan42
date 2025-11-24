class AddLlmApiKeyToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :llm_api_key, :string
  end
end
