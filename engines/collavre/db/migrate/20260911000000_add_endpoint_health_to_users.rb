# frozen_string_literal: true

class AddEndpointHealthToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :endpoint_health_status, :integer, default: 0, null: false
    add_column :users, :endpoint_health_checked_at, :datetime
    add_column :users, :endpoint_health_error, :string
  end
end
