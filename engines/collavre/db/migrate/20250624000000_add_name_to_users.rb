class AddNameToUsers < ActiveRecord::Migration[7.1]
  class User < ActiveRecord::Base; end

  def up
    add_column :users, :name, :string

    User.reset_column_information
    User.find_each do |user|
      user.update_columns(name: user.email.to_s.split('@').first)
    end

    change_column_null :users, :name, false
  end

  def down
    remove_column :users, :name
  end
end
