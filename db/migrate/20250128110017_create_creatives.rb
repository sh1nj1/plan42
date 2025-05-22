class CreateCreatives < ActiveRecord::Migration[8.0]
  def change
    create_table :creatives do |t|
      t.string :name
      t.text :description
      t.string :featured_image
      t.integer :inventory_count
      t.timestamps
    end
  end
end
