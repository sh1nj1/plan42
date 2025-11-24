class AddAiFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :system_prompt, :text
    add_column :users, :llm_vendor, :string
    add_column :users, :llm_model, :string
  end
end
