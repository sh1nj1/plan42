module CollavreOpenclaw
  module AiClientExtension
    extend ActiveSupport::Concern

    class_methods do
      def adapter_registry
        @adapter_registry ||= {}
      end

      def register_adapter(vendor, adapter_class)
        adapter_registry[vendor.to_s.downcase] = adapter_class
      end
    end

    # @param messages_input [Hash, Array] Hash { messages:, first_message:, context_changed: }
    #   from MessageBuilder, or a plain Array from standalone callers (e.g., CompressJob).
    def chat(messages_input, tools: [], &block)
      normalized_vendor = vendor.to_s.downcase
      messages_data = normalize_messages_input(messages_input)

      # Check if we have a custom adapter for this vendor
      adapter_class = self.class.adapter_registry[normalized_vendor]

      if adapter_class
        # Use the custom adapter (tools not supported for OpenClaw)
        user = context&.dig(:user)
        adapter = adapter_class.new(
          user: user,
          system_prompt: system_prompt,
          context: context
        )

        response_content = nil
        error_message = nil

        begin
          response_content = adapter.chat(messages_data, &block)
        rescue StandardError => e
          error_message = e.message
          raise
        ensure
          log_interaction(
            messages: messages_data[:messages],
            tools: [],
            response_content: response_content,
            error_message: error_message,
            input_tokens: nil,
            output_tokens: nil
          )
        end

        return response_content
      end

      # Fall back to original RubyLLM implementation (expects Array)
      super(messages_data[:messages], tools: tools, &block)
    end

    private

    attr_reader :vendor, :system_prompt, :context

    # Wrap plain Array input (from standalone callers like CompressJob)
    # into the Hash format expected by the adapter.
    def normalize_messages_input(input)
      return input if input.is_a?(Hash)

      {
        messages: Array(input).map { |m| m.merge(kind: :trigger) },
        first_message: true,
        context_changed: false
      }
    end
  end
end
