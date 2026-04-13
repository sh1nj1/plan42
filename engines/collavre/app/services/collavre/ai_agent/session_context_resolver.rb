# frozen_string_literal: true

module Collavre
  module AiAgent
    class SessionContextResolver
      CONTEXT_KINDS = %i[creative_context context_creative referenced_creative].freeze

      def initialize(agent:, messages_data:, system_prompt:)
        @agent = agent
        @messages_data = messages_data
        @system_prompt = system_prompt
      end

      def resolve
        if @agent.supports_session? && !needs_full_context?
          incremental_payload
        else
          full_payload
        end
      end

      private

      def needs_full_context?
        @messages_data[:first_message] || @messages_data[:context_changed]
      end

      def full_payload
        {
          messages: @messages_data[:messages],
          system_prompt: @system_prompt,
          first_message: @messages_data[:first_message],
          context_changed: @messages_data[:context_changed]
        }
      end

      def incremental_payload
        trigger_only = @messages_data[:messages].select { |m| m[:kind] == :trigger }

        {
          messages: trigger_only,
          system_prompt: nil,
          first_message: false,
          context_changed: false
        }
      end
    end
  end
end
