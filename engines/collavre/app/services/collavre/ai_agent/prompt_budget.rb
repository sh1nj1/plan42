# frozen_string_literal: true

module Collavre
  module AiAgent
    # Last line of defence on prompt size. Every section MessageBuilder adds
    # has its own budget, but they are configured independently, so their sum
    # can still exceed what a provider accepts (codex app-server rejects input
    # over 1,048,576 characters with input_too_large). A request that is too
    # large fails on every retry, so shrinking it is the only way the turn can
    # be answered at all.
    #
    # Over agent_conf `context.max_prompt_chars`, context is shed least
    # important first: the oldest chat history, then linked creatives, then
    # Context Creatives, then the current creative's subtree (its path line is
    # kept). The trigger is cut last, and only if it alone is over the cap.
    class PromptBudget
      DEFAULT_MAX_CHARS = 500_000
      SHED_ORDER = %i[chat_history referenced_creative context_creative].freeze
      TRUNCATED_NOTE = "\n\n(Message truncated to fit the context budget.)"

      def self.enforce!(messages, agent)
        new(messages, agent).enforce!
      end

      def initialize(messages, agent)
        @messages = messages
        @limit = (agent.parsed_agent_conf.dig("context", "max_prompt_chars") || DEFAULT_MAX_CHARS).to_i
      end

      def enforce!
        return @messages if total <= @limit

        Rails.logger.warn("[PromptBudget] prompt of #{total} chars exceeds #{@limit}; shedding context")
        SHED_ORDER.each { |kind| shed(kind) }
        shrink_creative_context if total > @limit
        cut_trigger if total > @limit
        @messages
      end

      private

      # Chat history goes oldest first. Linked and Context Creatives are in
      # priority order, so they go from the back.
      def shed(kind)
        candidates = @messages.select { |m| m[:kind] == kind }
        candidates.reverse! unless kind == :chat_history
        candidates.each do |message|
          break if total <= @limit

          @messages.delete_if { |m| m.equal?(message) }
        end
      end

      def total
        @messages.sum { |m| text_size(m) }
      end

      def text_size(message)
        message[:parts].sum { |part| part[:text].to_s.length }
      end

      def shrink_creative_context
        message = @messages.find { |m| m[:kind] == :creative_context }
        return unless message

        part = message[:parts].first
        part[:text] = part[:text].lines.take_while { |l| l.start_with?("Creative Path:", "Topic:") }.join.chomp
      end

      # Applies to the text parts of the trigger only; images ride untouched.
      def cut_trigger
        message = @messages.find { |m| m[:kind] == :trigger }
        return unless message

        part = message[:parts].select { |p| p[:text] }.max_by { |p| p[:text].length }
        return unless part

        room = @limit - (total - part[:text].length) - TRUNCATED_NOTE.length
        part[:text] = "#{part[:text][0, [ room, 0 ].max]}#{TRUNCATED_NOTE}"
      end
    end
  end
end
