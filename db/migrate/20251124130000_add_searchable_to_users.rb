class AddSearchableToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :searchable, :boolean, default: false, null: false
    add_index :users, :searchable
  end
end
