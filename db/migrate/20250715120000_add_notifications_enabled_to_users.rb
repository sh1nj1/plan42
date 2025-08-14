class AddNotificationsEnabledToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :notifications_enabled, :boolean
  end
end
