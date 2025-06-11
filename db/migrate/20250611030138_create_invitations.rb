class CreateInvitations < ActiveRecord::Migration[8.0]
  def change
    create_table :invitations do |t|
      t.string :email
      t.references :inviter, null: false, foreign_key: { to_table: :users }
      t.references :creative, null: false, foreign_key: true
      t.integer :permission
      t.datetime :expires_at
      t.datetime :clicked_at
      t.datetime :accepted_at

      t.timestamps
    end
  end
end
