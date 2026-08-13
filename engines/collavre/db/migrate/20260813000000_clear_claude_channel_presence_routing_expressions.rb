# frozen_string_literal: true

class ClearClaudeChannelPresenceRoutingExpressions < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL.squish
      UPDATE users
      SET routing_expression = NULL
      WHERE llm_model = 'claude-code'
        AND routing_expression = 'true'
    SQL
  end

  def down
    # Presence rows, not routing_expression, now own Claude Channel liveness.
  end
end
