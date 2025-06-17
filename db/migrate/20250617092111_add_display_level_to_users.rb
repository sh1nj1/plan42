class AddDisplayLevelToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :display_level, :integer, default: 6, null: false
  end
end
