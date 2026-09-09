# frozen_string_literal: true

module Collavre
  module Topics
    # Resolves the `primary_agent` string an MCP caller passes into a User.
    #
    # The UI picks an agent from a palette and sends an id; an agent calling a
    # tool has read a name out of a conversation and has no palette to click.
    # Accepting id / email / display name is what makes topic_create and
    # topic_update usable without a preceding lookup round-trip.
    #
    # Candidates are the owned-or-searchable set plus agents already shared on
    # the target Creative. The latter matches User.mentionable_for and the UI's
    # agent palette. Resolving over every agent row would let a caller confirm a
    # private agent's existence by name, and would let them pin one they are not
    # allowed to see.
    module AgentResolver
      # Sentinel distinguishing "clear the pin" from "no change". A blank string
      # cannot carry that difference on its own: topic_update omitting the
      # parameter and topic_update asking to unassign both arrive as falsy.
      CLEAR = :clear

      # What a caller writes to mean "unassign". Spelled out because an agent
      # that guesses will guess one of these.
      CLEAR_TOKENS = %w[none clear null nil unassign].freeze

      class AmbiguousAgentError < ArgumentError; end
      class UnknownAgentError < ArgumentError; end

      module_function

      # Returns nil (no change), CLEAR (unassign), or a User.
      def call(value, actor: Collavre::Current.user, creative: nil)
        token = value.to_s.strip
        return nil if value.nil?
        return CLEAR if token.empty? || CLEAR_TOKENS.include?(token.downcase)

        candidates = candidates_for(actor, creative)
        find_by_id(candidates, token) ||
          find_by_email(candidates, token) ||
          find_by_name(candidates, token) ||
          raise(UnknownAgentError, unknown_message(token))
      end

      def candidates_for(actor, creative)
        accessible = User.accessible_ai_agents_for(actor)
        return accessible unless creative

        shared = User.mentionable_for(creative).ai_agents
        base = User.ai_agents
        base.where(id: accessible.reorder(nil).select(:id))
            .or(base.where(id: shared.reorder(nil).select(:id)))
            .distinct.order(:name)
      end

      def find_by_id(candidates, token)
        return nil unless token.match?(/\A\d+\z/)

        candidates.find_by(id: token.to_i)
      end

      def find_by_email(candidates, token)
        return nil unless token.include?("@")

        candidates.find_by(email: token.downcase)
      end

      # Names are not unique, so an exact-match tie is reported with the ids
      # rather than silently resolved to the first row — picking one would
      # quietly dedicate a topic to the wrong agent.
      def find_by_name(candidates, token)
        matches = candidates.where(name: token).to_a
        return matches.first if matches.one?
        return nil if matches.empty?

        raise AmbiguousAgentError,
          "Multiple agents named #{token.inspect}: ids #{matches.map(&:id).join(', ')}. Pass the id instead."
      end

      def unknown_message(token)
        "No accessible AI agent matches #{token.inspect}. " \
          "Pass an agent id, email, or exact name; the agent must be searchable, created by you, " \
          "or already shared on this creative."
      end
    end
  end
end
