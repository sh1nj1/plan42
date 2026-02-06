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
    # - bid: Select agent based on relevance score (expertise matching)
    #
    class Arbiter
      # Default confidence threshold for bid strategy
      DEFAULT_CONFIDENCE_THRESHOLD = 0.3
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
        when "bid"
          strategy_bid(candidates)
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

      # Rotate between agents using Rails cache for state
      def strategy_round_robin(candidates)
        return candidates.take(1) if candidates.size <= 1

        topic_id = @context.dig("topic", "id")
        return candidates.take(1) if topic_id.blank?

        # Sort candidates by id for consistent ordering
        sorted_candidates = candidates.sort_by(&:id)

        # Get last responder from cache
        cache_key = "orchestrator:round_robin:topic:#{topic_id}"
        last_responder_id = Rails.cache.read(cache_key)

        # Find next agent in rotation
        selected = if last_responder_id.present?
                     find_next_in_rotation(sorted_candidates, last_responder_id)
        else
                     sorted_candidates.first
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

      # Select agent based on relevance/expertise scoring
      # Returns highest scoring agent if above threshold, otherwise empty
      def strategy_bid(candidates)
        return [] if candidates.empty?

        threshold = @policy_resolver.confidence_threshold || DEFAULT_CONFIDENCE_THRESHOLD
        message_text = extract_message_text

        # Score each candidate
        scored = candidates.map do |agent|
          score = calculate_relevance_score(agent, message_text)
          { agent: agent, score: score }
        end

        # Sort by score descending
        scored.sort_by! { |s| -s[:score] }

        # Return highest scoring agent if above threshold
        best = scored.first
        if best[:score] >= threshold
          [ best[:agent] ]
        else
          # No agent meets threshold - return empty or fallback to first
          # Based on policy, could return first candidate as fallback
          @policy_resolver.bid_fallback_enabled? ? [ candidates.first ] : []
        end
      end

      # Calculate relevance score for an agent (0.0 - 1.0)
      def calculate_relevance_score(agent, message_text)
        return 0.0 if message_text.blank?

        scores = []

        # 1. Keyword matching with agent's expertise/system_prompt
        keyword_score = calculate_keyword_score(agent, message_text)
        scores << keyword_score * 0.5  # 50% weight

        # 2. Recent conversation participation
        participation_score = calculate_participation_score(agent)
        scores << participation_score * 0.3  # 30% weight

        # 3. Agent specialty tags (if defined in metadata)
        specialty_score = calculate_specialty_score(agent, message_text)
        scores << specialty_score * 0.2  # 20% weight

        scores.sum
      end

      def extract_message_text
        # Extract text from the triggering comment
        @context.dig("comment", "content") ||
          @context.dig("comment", "body") ||
          @context.dig("message", "content") ||
          ""
      end

      # Score based on keyword overlap between message and agent's expertise
      def calculate_keyword_score(agent, message_text)
        expertise_text = extract_expertise_text(agent)
        return 0.0 if expertise_text.blank?

        message_words = tokenize(message_text.downcase)
        expertise_words = tokenize(expertise_text.downcase)

        return 0.0 if message_words.empty? || expertise_words.empty?

        # Calculate Jaccard-like similarity
        common_words = message_words & expertise_words
        union_size = (message_words + expertise_words).uniq.size

        return 0.0 if union_size.zero?

        # Weighted by how many message words appear in expertise
        # (more relevant if agent knows about what user is asking)
        message_coverage = common_words.size.to_f / message_words.size
        expertise_density = common_words.size.to_f / [ expertise_words.size, 50 ].min

        (message_coverage * 0.7 + expertise_density * 0.3).clamp(0.0, 1.0)
      end

      def extract_expertise_text(agent)
        texts = []

        # From agent's system_prompt (primary source for AI agents)
        texts << agent.system_prompt if agent.respond_to?(:system_prompt) && agent.system_prompt.present?

        # From AI agent profile (for nested ai_agent association)
        if agent.respond_to?(:ai_agent) && agent.ai_agent.present?
          texts << agent.ai_agent.system_prompt if agent.ai_agent.respond_to?(:system_prompt)
          texts << agent.ai_agent.description if agent.ai_agent.respond_to?(:description)
        end

        # From name (can indicate specialty)
        texts << agent.name if agent.respond_to?(:name)

        texts.compact.join(" ")
      end

      # Score based on recent participation in this topic
      def calculate_participation_score(agent)
        topic_id = @context.dig("topic", "id")
        return 0.0 if topic_id.blank?

        # Check cache for recent comments by this agent in topic
        cache_key = "orchestrator:participation:topic:#{topic_id}:agent:#{agent.id}"
        cached = Rails.cache.read(cache_key)
        return cached if cached.present?

        # Query recent comments (last 24 hours)
        recent_count = Comment
          .where(topic_id: topic_id, user_id: agent.id)
          .where("created_at > ?", 24.hours.ago)
          .count

        # Normalize: 0 comments = 0, 5+ comments = 1.0
        score = [ recent_count / 5.0, 1.0 ].min

        Rails.cache.write(cache_key, score, expires_in: 5.minutes)
        score
      end

      # Score based on specialty tags matching message content
      def calculate_specialty_score(agent, message_text)
        return 0.0 unless agent.respond_to?(:metadata)

        tags = agent.metadata&.dig("specialty_tags") || []
        return 0.0 if tags.empty?

        message_lower = message_text.downcase
        matched = tags.count { |tag| message_lower.include?(tag.to_s.downcase) }

        [ matched.to_f / tags.size, 1.0 ].min
      end

      # Simple tokenization for keyword matching
      def tokenize(text)
        # Remove punctuation, split by whitespace, filter short words
        text
          .gsub(/[^\p{L}\p{N}\s]/, " ")
          .split(/\s+/)
          .reject { |w| w.length < 3 }
          .uniq
      end
    end
  end
end
