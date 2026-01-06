class AllowNullUserIdInCreativeShares < ActiveRecord::Migration[8.1]
  def change
    change_column_null :creative_shares, :user_id, true
    add_index :creative_shares, :creative_id, unique: true, where: "user_id IS NULL", name: "index_creative_shares_on_creative_id_public"
  end
end
