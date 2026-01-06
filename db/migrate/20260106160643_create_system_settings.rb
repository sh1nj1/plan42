class CreateSystemSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :system_settings do |t|
      t.string :key
      t.text :value

      t.timestamps
    end
    add_index :system_settings, :key, unique: true
  end
end
