class AddOwnerToLabels < ActiveRecord::Migration[6.1]
  def change
    add_reference :labels, :owner, foreign_key: { to_table: :users }
  end
end
