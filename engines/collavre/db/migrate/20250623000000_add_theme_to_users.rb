class AddThemeToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :theme, :string
  end
end
