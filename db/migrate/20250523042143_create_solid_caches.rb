class CreateSolidCaches < ActiveRecord::Migration[8.0]
  def change
    create_table "solid_cable_messages", force: :cascade do |t|
      t.binary "channel", limit: 1024, null: false
      t.binary "payload", limit: 536870912, null: false
      t.datetime "created_at", null: false
      t.integer "channel_hash", limit: 8, null: false
      t.index [ "channel" ], name: "index_solid_cable_messages_on_channel"
      t.index [ "channel_hash" ], name: "index_solid_cable_messages_on_channel_hash"
      t.index [ "created_at" ], name: "index_solid_cable_messages_on_created_at"
    end

    create_table "solid_cache_entries", force: :cascade do |t|
      t.binary "key", limit: 1024, null: false
      t.binary "value", limit: 536870912, null: false
      t.datetime "created_at", null: false
      t.integer "key_hash", limit: 8, null: false
      t.integer "byte_size", limit: 4, null: false
      t.index [ "byte_size" ], name: "index_solid_cache_entries_on_byte_size"
      t.index [ "key_hash", "byte_size" ], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
      t.index [ "key_hash" ], name: "index_solid_cache_entries_on_key_hash", unique: true
    end
  end
end
