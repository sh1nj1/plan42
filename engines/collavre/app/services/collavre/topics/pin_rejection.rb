# frozen_string_literal: true

module Collavre
  module Topics
    # Explains a Topic.primary_agent_rejection symbol to an MCP caller.
    #
    # The rejection reasons need different advice and the difference matters: sharing
    # the creative fixes a missing-permission rejection, while a Claude Channel
    # session agent stays confined to its own session topic no matter what is
    # shared. Telling a caller to share in that second case sends it after a fix
    # that cannot work — the same distinction TopicsController draws for humans.
    module PinRejection
      module_function

      def locale_key(rejection)
        { chat_not_supported: "agent_chat_not_supported",
          session_agent_outside_session_topic: "session_agent_not_assignable" }
          .fetch(rejection, "agent_no_creative_access")
      end

      def release_locale_key(rejection)
        { chat_not_supported: "primary_agent_released_chat_not_supported",
          session_agent_outside_session_topic: "primary_agent_released_session_agent" }
          .fetch(rejection, "primary_agent_released")
      end

      def message(agent, rejection)
        if rejection == :chat_not_supported
          I18n.t("collavre.topics.agent_chat_not_supported", name: agent.display_name)
        elsif rejection == :session_agent_outside_session_topic
          "#{agent.display_name} is a session agent and can only be pinned to its own session topic."
        else
          "#{agent.display_name} has no feedback permission on this creative, so it cannot be pinned. " \
            "Share the creative with the agent at feedback or higher first."
        end
      end
    end
  end
end
