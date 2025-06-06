class RenameEmailAddressToEmailInUsers < ActiveRecord::Migration[8.0]
  def change
    remove_index :users, name: :index_users_on_email_address
    rename_column :users, :email_address, :email
    add_index :users, :email, unique: true
  end
end
