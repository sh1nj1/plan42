# frozen_string_literal: true

module Collavre
  module Creatives
    class AgentTurnHistory
      def self.call(agent, workspace_user, task)
        Current.set(user: agent, agent_turn: { user: workspace_user, task: task }) do
          yield
        ensure
          History.finish_agent_turn
        end
      end
    end
  end
end
