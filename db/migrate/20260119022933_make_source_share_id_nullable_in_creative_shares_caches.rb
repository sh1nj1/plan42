class MakeSourceShareIdNullableInCreativeSharesCaches < ActiveRecord::Migration[8.1]
  def change
    change_column_null :creative_shares_caches, :source_share_id, true
    remove_foreign_key :creative_shares_caches, :creative_shares
    add_foreign_key :creative_shares_caches, :creative_shares, column: :source_share_id, on_delete: :cascade, validate: false
  end
end
