class AddLastVisitedCreativeAtToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :last_visited_creative_at, :datetime
  end
end
