class CreateComments < ActiveRecord::Migration[7.0]
  def change
    create_table :comments, if_not_exists: true do |t|
      t.references :creative, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.text :content, null: false
      t.timestamps
    end
  end
end
