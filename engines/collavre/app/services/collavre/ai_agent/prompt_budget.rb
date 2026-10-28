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
        @limit = (agent.parsed_agent_conf.dig("context", "max_prompt_chars") || DEFAULT_MAX_CHARS).to_i.clamp(0, Float::INFINITY)
      end

      def enforce!
        return @messages if total <= @limit

        Rails.logger.warn("[PromptBudget] prompt of #{total} chars exceeds #{@limit}; shedding context")
        SHED_ORDER.each { |kind| shed(kind) }
        shrink_creative_context if total > @limit
        bound_retained_context if total > @limit
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

      # Reserve the remaining budget for the request, even when breadcrumbs
      # or other retained messages alone exceed the configured cap.
      def bound_retained_context
        @messages.reject { |m| m[:kind] == :trigger }.reverse_each do |message|
          message[:parts].reverse_each do |part|
            next unless part[:text]
            break if total <= @limit

            part[:text] = part[:text][0, [ part[:text].length - (total - @limit), 0 ].max]
          end
        end
      end

      # The anchor follows merged comments and resume context. Drop that prefix
      # first so an older instruction cannot displace the current request.
      def cut_trigger
        @messages.select { |m| m[:kind] == :trigger }.each do |message|
          prioritize_anchor(message)
          message[:parts].select { |p| p[:text] }.sort_by { |p| -p[:text].length }.each do |part|
            break if total <= @limit

            room = [ @limit - (total - part[:text].length), 0 ].max
            note = TRUNCATED_NOTE[0, room]
            part[:text] = "#{part[:text][0, room - note.length]}#{note}"
          end
        end
      end

      def prioritize_anchor(message)
        message[:parts].each do |part|
          next unless part[:anchor_offset].to_i.positive?

          part[:text] = part[:text][part[:anchor_offset]..]
          part[:anchor_offset] = 0
        end
      end
    end
  end
end
