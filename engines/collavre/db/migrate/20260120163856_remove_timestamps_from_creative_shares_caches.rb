class RemoveTimestampsFromCreativeSharesCaches < ActiveRecord::Migration[8.1]
  def change
    remove_column :creative_shares_caches, :created_at, :datetime
    remove_column :creative_shares_caches, :updated_at, :datetime
  end
end
