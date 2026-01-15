class CreateCreativeLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :creative_links do |t|
      t.references :parent, null: false, foreign_key: { to_table: :creatives }
      t.references :origin, null: false, foreign_key: { to_table: :creatives }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.integer :sequence, default: 0, null: false
      t.timestamps
    end

    add_index :creative_links, [:parent_id, :origin_id], unique: true
    add_index :creative_links, [:parent_id, :sequence]
  end
end
