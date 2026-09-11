class AddLastVisitedCreativeNavigationOrderToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :last_visited_creative_client_id, :string
    add_column :users, :last_visited_creative_visit_sequence, :bigint
  end
end
