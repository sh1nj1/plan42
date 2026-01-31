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
        # Use the custom adapter
        user = context&.dig(:user)
        adapter = adapter_class.new(
          user: user,
          system_prompt: system_prompt,
          context: context
        )
        return adapter.chat(contents, tools: tools, &block)
      end

      # Fall back to original implementation
      super
    end

    private

    attr_reader :vendor, :system_prompt, :context
  end
end
