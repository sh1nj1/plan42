class AddDeletingAtToComments < ActiveRecord::Migration[8.0]
  def change
    add_column :comments, :deleting_at, :datetime
  end
end
