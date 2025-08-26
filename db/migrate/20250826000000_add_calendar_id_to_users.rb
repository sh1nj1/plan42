class AddCalendarIdToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :calendar_id, :string
  end
end
