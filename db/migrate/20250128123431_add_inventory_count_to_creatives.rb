class AddInventoryCountToCreatives < ActiveRecord::Migration[8.0]
  def change
    add_column :creatives, :inventory_count, :integer
  end
end
