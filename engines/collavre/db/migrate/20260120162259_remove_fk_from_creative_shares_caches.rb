class RemoveFkFromCreativeSharesCaches < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :creative_shares_caches, :creatives, if_exists: true
    remove_foreign_key :creative_shares_caches, :users, if_exists: true
    remove_foreign_key :creative_shares_caches, column: :source_share_id, if_exists: true
  end
end
