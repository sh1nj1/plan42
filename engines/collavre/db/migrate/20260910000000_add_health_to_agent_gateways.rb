# frozen_string_literal: true

class AddHealthToAgentGateways < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_gateways, :health_status, :integer, default: 0, null: false
    add_column :agent_gateways, :health_checked_at, :datetime
    add_column :agent_gateways, :health_engines, :json, default: {}, null: false
    add_column :agent_gateways, :health_error, :string
  end
end
