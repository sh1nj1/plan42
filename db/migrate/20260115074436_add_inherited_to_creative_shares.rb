class AddInheritedToCreativeShares < ActiveRecord::Migration[8.1]
  def change
    add_column :creative_shares, :inherited, :boolean, default: false, null: false

    add_index :creative_shares, [:user_id, :inherited]
    add_index :creative_shares, [:creative_id, :user_id], unique: true, name: "idx_creative_shares_creative_user"
  end
end
