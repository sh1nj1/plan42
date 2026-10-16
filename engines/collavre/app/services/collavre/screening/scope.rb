# frozen_string_literal: true

module Collavre
  module Screening
    # Which turns are screened: those that carry text from someone other than
    # the agent's owner. The owner instructing their own agent is not an
    # injection; the principal alone does not say who wrote the text, so the
    # authors of the turn's comments are checked too.
    class Scope
      # :skip | :screen
      def self.for(agent:, context:, principal:, authors: [])
        # A carried-but-unverifiable principal (an AI-authored anchor) is not
        # the owner by default.
        return :screen if context&.key?("workspace_user_id") && principal.nil?
        return :screen if principal && principal.id != agent.created_by_id
        return :screen if authors.any? { |author| foreign?(author, agent) }

        :skip
      end

      # The owner, the agent itself and the owner's other agents are trusted
      # authors; anyone else, including another person's agent, is not.
      def self.foreign?(author, agent)
        owner_id = agent.created_by_id
        return false if author.id == agent.id
        return owner_id.nil? || author.created_by_id != owner_id if author.ai_user?

        author.id != owner_id
      end
    end
  end
end
