# frozen_string_literal: true

module Collavre
  module CliProxy
    # Replays must still match current routing, including after a coalesced
    # source is withdrawn. Assignment permission alone does not select an agent.
    module ReplayRouting
      def self.permitted?(payload, agent)
        prepare(payload, agent).present?
      end

      # Return the exact anchor snapshot that passed routing, for persistence
      # and delivery. A waiting task's cached text/mentions are not authoritative.
      def self.prepare(payload, agent)
        return unless ReplayWorkspace.permitted?(payload, agent)

        Comment.uncached do
          source = AiAgent::MergedTriggerComments.in_turn([ payload.dig("comment", "id") ], payload).first
          next unless source

          current = Orchestration::TaskCoalescer.reanchor_payload(payload, source)
          current if selected?(current, agent)
        end
      end

      def self.selected?(payload, agent)
        return true if matches?(payload, agent)

        # Only current, public siblings in this turn can authorize its replay.
        ids = Array(payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]).compact
        AiAgent::MergedTriggerComments.in_turn(ids, payload).pluck(:content).any? do |content|
          matches?(payload.merge("chat" => { "content" => content }), agent)
        end
      end

      def self.matches?(payload, agent)
        context = SystemEvents::ContextBuilder.new(payload).build
        Orchestration::Matcher.new(context).match.include?(agent)
      end
      private_class_method :selected?, :matches?
    end
  end
end
