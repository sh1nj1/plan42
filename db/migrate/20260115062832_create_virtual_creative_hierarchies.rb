class CreateVirtualCreativeHierarchies < ActiveRecord::Migration[8.1]
  def change
    create_table :virtual_creative_hierarchies do |t|
      t.references :ancestor, null: false, foreign_key: { to_table: :creatives }
      t.references :descendant, null: false, foreign_key: { to_table: :creatives }
      t.integer :generations, null: false, default: 0
      t.references :creative_link, null: false, foreign_key: true
      t.timestamps
    end

    add_index :virtual_creative_hierarchies, [ :ancestor_id, :descendant_id ], unique: true, name: "idx_vch_ancestor_descendant"
    # Note: descendant_id index is already created by t.references
  end
end
