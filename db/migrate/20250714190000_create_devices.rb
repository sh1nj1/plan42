class CreateDevices < ActiveRecord::Migration[8.0]
  def change
    create_table :devices do |t|
      t.references :user, null: false, foreign_key: true
      t.string :client_id, null: false
      t.integer :device_type, null: false
      t.string :app_id
      t.string :app_version
      t.string :fcm_token, null: false

      t.timestamps
    end

    add_index :devices, :client_id, unique: true
    add_index :devices, :fcm_token
  end
end
