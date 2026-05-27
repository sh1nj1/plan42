class AddDismissedAtToChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :channels, :dismissed_at, :datetime
    add_index :channels, :dismissed_at
  end
end
