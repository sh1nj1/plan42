class AddActionAndApproverToComments < ActiveRecord::Migration[8.0]
  def change
    add_column :comments, :action, :text
    add_reference :comments, :approver, foreign_key: { to_table: :users }
  end
end
