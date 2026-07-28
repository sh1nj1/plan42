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

    # @param messages_input [Hash, Array] Hash { messages:, first_message:, context_changed:, system_prompt: }
    #   from SessionContextResolver, or a plain Array from standalone callers (e.g., CompressJob).
    def chat(messages_input, tools: [], &block)
      # Cleared on the way in, as the base #chat clears it — the flag describes
      # the last request, and this branch never reaches `super`. A client is
      # reused across a turn's calls, so a failure left standing would have
      # every later one claiming it delivered nothing.
      @last_handoff_failed = false
      @handed_off = false
      normalized_vendor = vendor.to_s.downcase
      messages_data = normalize_messages_input(messages_input)

      # Check if we have a custom adapter for this vendor
      adapter_class = self.class.adapter_registry[normalized_vendor]

      if adapter_class
        # Use the custom adapter (tools not supported for OpenClaw)
        # Prefer resolved system_prompt from SessionContextResolver over instance default.
        # key?(:system_prompt) distinguishes "not provided" (Array input) from "explicitly nil" (incremental session).
        resolved_system_prompt = messages_data.key?(:system_prompt) ? messages_data[:system_prompt] : system_prompt
        user = context&.dig(:user)
        adapter = adapter_class.new(
          user: user,
          system_prompt: resolved_system_prompt,
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
          # Honor no-log mode (e.g. inline typo correction on *unsubmitted* drafts).
          # Base Collavre::AiClient#chat gates logging behind @log_interactions; this
          # prepended adapter path bypasses super, so it must gate it too — otherwise
          # private drafts leak to ActivityLog for OpenClaw-backed agents.
          if @log_interactions
            log_interaction(
              messages: messages_data[:messages],
              tools: [],
              response_content: response_content,
              error_message: error_message,
              input_tokens: nil,
              output_tokens: nil
            )
          end
        end

        # Whether the payload ever left the building. AiAgentService asks the
        # *client*, not the adapter, and marks the turn's
        # Orchestration::DeliveryRecord off the answer; the adapter converts
        # missing credentials and transport failures into a streamed error plus
        # nil, so without this an OpenClaw turn that reached nothing still ends
        # `done` with the flag down and the dispatches dropped against it are
        # never restored. See OpenclawAdapter#last_handoff_failed?.
        @last_handoff_failed = adapter.last_handoff_failed?
        # And the positive form beside it, for the reader the flag above cannot
        # serve: a turn stopped after the gateway had the payload.
        @handed_off = adapter.handed_off?

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
