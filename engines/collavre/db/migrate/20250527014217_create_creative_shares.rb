class CreateCreativeShares < ActiveRecord::Migration[6.1]
  def change
    create_table :creative_shares do |t|
      t.references :creative, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :permission, null: false, default: 0

      t.timestamps
    end
    add_index :creative_shares, [ :creative_id, :user_id ], unique: true
  end
end
