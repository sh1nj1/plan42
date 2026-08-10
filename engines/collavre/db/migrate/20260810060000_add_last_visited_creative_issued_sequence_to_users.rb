class AddLastVisitedCreativeIssuedSequenceToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :last_visited_creative_issued_sequence, :bigint
  end
end
