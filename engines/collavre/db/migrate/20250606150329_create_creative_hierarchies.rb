class CreateCreativeHierarchies < ActiveRecord::Migration[8.0]
  def change
    create_table :creative_hierarchies, id: false do |t|
      t.integer :ancestor_id, null: false
      t.integer :descendant_id, null: false
      t.integer :generations, null: false
    end

    add_index :creative_hierarchies, [ :ancestor_id, :descendant_id, :generations ],
      unique: true,
      name: "creative_anc_desc_idx"

    add_index :creative_hierarchies, [ :descendant_id ],
      name: "creative_desc_idx"
  end
end
