class CreateUserThemes < ActiveRecord::Migration[8.1]
  def change
    create_table :user_themes do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name
      t.json :variables

      t.timestamps
    end
  end
end
