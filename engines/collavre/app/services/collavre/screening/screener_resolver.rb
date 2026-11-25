# frozen_string_literal: true

module Collavre
  module Screening
    # The system screener protects every agent. A judge agent shared on the
    # creative with feedback or higher takes over only when the protected
    # agent's owner owns it too; anyone else's judge (a creative admin can
    # share their own) screens alongside the system and can only tighten.
    class ScreenerResolver
      def self.for(agent:, creative:, task:)
        custom = creative&.find_ai_agent(:feedback, capability: :judge, excluding: agent.id)
        custom = nil unless custom && Creatives::PermissionChecker.current_allowed?(creative.id, custom, :feedback)
        system = Screener.system(agent: agent, task: task)
        return [ system ] unless custom

        judge = Screener.agent(custom, task: task)
        return [ judge ] if agent.created_by_id.present? && custom.created_by_id == agent.created_by_id

        [ system, judge ]
      end
    end
  end
end
