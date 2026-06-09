# frozen_string_literal: true

module Collavre
  # Presence record for one live Claude Channel session subscription on the
  # per-agent ActionCable stream. The set of rows for an agent_id is the
  # authority for whether routing_expression should be active: a human's
  # concurrent sessions share one agent, so routing stays on while ANY session
  # holds a row, and only turns off when the last row is removed.
  class AgentSubscription < ApplicationRecord
    self.table_name = "agent_subscriptions"

    belongs_to :agent, class_name: Collavre.configuration.user_class_name
  end
end
