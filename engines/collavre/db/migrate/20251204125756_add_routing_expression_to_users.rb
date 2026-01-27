class AddRoutingExpressionToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :routing_expression, :text
  end
end
