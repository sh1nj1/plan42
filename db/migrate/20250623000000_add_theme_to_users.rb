class AddThemeToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :theme, :string, null: false, default: 'light'
  end
end
