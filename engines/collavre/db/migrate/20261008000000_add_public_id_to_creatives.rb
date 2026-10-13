class AddPublicIdToCreatives < ActiveRecord::Migration[8.0]
  def change
    add_column :creatives, :public_id, :string
    add_index :creatives, :public_id, unique: true
  end
end
