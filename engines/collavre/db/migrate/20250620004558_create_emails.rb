class CreateEmails < ActiveRecord::Migration[8.0]
  def change
    create_table :emails do |t|
      t.references :user, null: true, foreign_key: true
      t.string :email, null: false
      t.string :subject, null: false
      t.text :body
      t.string :event, null: false

      t.timestamps
    end
  end
end
