class AddCompletionMarkToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :completion_mark, :string, default: "", null: false
  end
end
