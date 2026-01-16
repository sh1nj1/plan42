class CreateCreativeSharesCache < ActiveRecord::Migration[8.1]
  def change
    create_table :creative_shares_caches do |t|
      t.references :creative, null: false, foreign_key: true
      t.references :user, null: true, foreign_key: true
      t.integer :permission, null: false
      t.references :source_share, null: false, foreign_key: { to_table: :creative_shares }
      t.timestamps
    end

    add_index :creative_shares_caches, [ :creative_id, :user_id ], unique: true
    add_index :creative_shares_caches, [ :user_id, :permission ]
    # source_share_id index is already created by t.references
  end
end
