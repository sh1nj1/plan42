# frozen_string_literal: true

module Collavre
  module AiAgent
    class SessionContextResolver
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
        msgs = if @agent.supports_session?
                 @messages_data[:messages].reject { |m| m[:kind] == :chat_history }
               else
                 @messages_data[:messages]
               end

        {
          messages: msgs,
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
