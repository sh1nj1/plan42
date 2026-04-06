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

    def chat(contents, tools: [], &block)
      normalized_vendor = vendor.to_s.downcase

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

        # contents may be a Hash { messages:, first_message:, context_changed: }
        # or a plain Array for backward compatibility
        log_messages = contents.is_a?(Hash) ? contents[:messages] : Array(contents)

        response_content = nil
        error_message = nil

        begin
          response_content = adapter.chat(contents, &block)
        rescue StandardError => e
          error_message = e.message
          raise
        ensure
          log_interaction(
            messages: log_messages,
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
      raw_messages = contents.is_a?(Hash) ? contents[:messages] : contents
      super(raw_messages, tools: tools, &block)
    end

    private

    attr_reader :vendor, :system_prompt, :context
  end
end
