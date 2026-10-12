# frozen_string_literal: true

# Access-granting blob flags (operator publish, CDN-cached marker) live here
# instead of active_storage_blobs.metadata: ActiveStorage's analyzer rewrites
# that whole column from a snapshot taken before a slow analysis, which could
# erase or resurrect a flag written in between.
class CreateBlobAccessFlags < ActiveRecord::Migration[8.0]
  def change
    create_table :blob_access_flags do |t|
      t.bigint :blob_id, null: false
      t.boolean :public_asset, null: false, default: false
      t.boolean :cdn_public, null: false, default: false
      t.timestamps
    end
    add_index :blob_access_flags, :blob_id, unique: true
  end
end
