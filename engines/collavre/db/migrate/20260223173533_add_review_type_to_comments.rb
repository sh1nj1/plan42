class AddReviewTypeToComments < ActiveRecord::Migration[8.0]
  def change
    add_column :comments, :review_type, :integer, limit: 1
  end
end
