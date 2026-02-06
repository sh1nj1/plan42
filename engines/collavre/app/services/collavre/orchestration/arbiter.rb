# frozen_string_literal: true

module Collavre
  module Orchestration
    # Arbiter decides which agents will actually respond from the qualified candidates.
    # This implements "floor control" - preventing multiple agents from responding simultaneously.
    #
    # Strategies:
    # - all: All candidates respond (original behavior)
    # - primary_first: Primary agent responds, others only if primary unavailable
    # - round_robin: Rotate between agents for each message
    #
    class Arbiter
      def initialize(context, policy_resolver: nil)
        @context = context
        @policy_resolver = policy_resolver || PolicyResolver.new(context)
      end

      # Select which agents will respond from the candidates
      # @param candidates [Array<User>] Qualified agents from Matcher
      # @return [Array<User>] Agents that will actually respond
      def select(candidates)
        return [] if candidates.empty?

        strategy = @policy_resolver.arbitration_strategy
        selected = apply_strategy(strategy, candidates)

        # Apply max_responders limit if set
        max = @policy_resolver.max_responders
        selected = selected.take(max) if max.present? && max.positive?

        selected
      end

      private

      def apply_strategy(strategy, candidates)
        case strategy
        when "all"
          strategy_all(candidates)
        when "primary_first"
          strategy_primary_first(candidates)
        when "round_robin"
          strategy_round_robin(candidates)
        else
          # Unknown strategy, default to all
          Rails.logger.warn("[Arbiter] Unknown strategy '#{strategy}', falling back to 'all'")
          strategy_all(candidates)
        end
      end

      # All candidates respond
      def strategy_all(candidates)
        candidates
      end

      # Primary agent responds if available, otherwise first candidate
      def strategy_primary_first(candidates)
        primary_id = @policy_resolver.primary_agent_id
        return candidates.take(1) if primary_id.blank?

        primary = candidates.find { |agent| agent.id == primary_id }
        primary ? [ primary ] : candidates.take(1)
      end

      # Rotate between agents using Redis for state
      def strategy_round_robin(candidates)
        return candidates.take(1) if candidates.size <= 1

        topic_id = @context.dig("topic", "id")
        return candidates.take(1) if topic_id.blank?

        # Get last responder from cache
        cache_key = "orchestrator:round_robin:topic:#{topic_id}"
        last_responder_id = Rails.cache.read(cache_key)

        # Find next agent in rotation
        selected = if last_responder_id.present?
                     find_next_in_rotation(candidates, last_responder_id)
        else
                     candidates.first
        end

        # Store current responder for next rotation
        Rails.cache.write(cache_key, selected.id, expires_in: 24.hours)

        [ selected ]
      end

      def find_next_in_rotation(candidates, last_responder_id)
        last_index = candidates.find_index { |a| a.id == last_responder_id }

        if last_index.nil?
          # Last responder not in current candidates, start from beginning
          candidates.first
        else
          # Get next agent, wrapping around to beginning
          next_index = (last_index + 1) % candidates.size
          candidates[next_index]
        end
      end
    end
  end
end
