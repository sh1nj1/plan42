class AddCreativeIdToLabels < ActiveRecord::Migration[8.1]
  def change
    add_reference :labels, :creative, foreign_key: true
  end
end
