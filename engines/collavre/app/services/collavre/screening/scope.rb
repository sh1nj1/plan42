# frozen_string_literal: true

module Collavre
  module Screening
    # Which turns are screened: those whose human principal is not the agent's
    # owner. The owner instructing their own agent is not an injection.
    class Scope
      # :skip | :screen
      def self.for(agent:, context:, principal:)
        # A carried-but-unverifiable principal (an AI-authored anchor) is not
        # the owner by default.
        return :screen if context&.key?("workspace_user_id") && principal.nil?
        return :skip if principal.nil? || principal.id == agent.created_by_id

        :screen
      end
    end
  end
end
