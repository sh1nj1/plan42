class AddDismissedNoticesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :dismissed_notices, :json
  end
end
