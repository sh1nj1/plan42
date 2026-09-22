# frozen_string_literal: true

module Collavre
  module Orchestration
    SchedulingHooks = Data.define(:interaction_callback, :scheduled_callback) do
      def interaction_for(agent) = interaction_callback&.call(agent)
      def scheduled(agents) = scheduled_callback&.call(agents)
    end
  end
end
