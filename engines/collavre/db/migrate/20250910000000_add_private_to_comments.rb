class AddPrivateToComments < ActiveRecord::Migration[7.0]
  def change
    add_column :comments, :private, :boolean, default: false, null: false
  end
end
