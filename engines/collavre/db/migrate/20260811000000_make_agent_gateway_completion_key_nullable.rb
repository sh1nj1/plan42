# frozen_string_literal: true

class MakeAgentGatewayCompletionKeyNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :agent_gateways, :completion_key, true
  end
end
