class CreateIntegrationSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :integration_settings do |t|
      t.string  :key, null: false
      t.text    :value
      t.string  :category, null: false
      t.boolean :sensitive, null: false, default: true
      t.boolean :seeded_from_env, null: false, default: false

      t.timestamps
    end

    add_index :integration_settings, :key, unique: true
    add_index :integration_settings, :category
  end
end
