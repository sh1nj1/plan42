class AddLastVisitedCreativeToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :last_visited_creative, foreign_key: {
      to_table: :creatives,
      on_delete: :nullify
    }
  end
end
