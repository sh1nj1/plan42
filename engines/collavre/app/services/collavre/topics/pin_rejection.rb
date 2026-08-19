# frozen_string_literal: true

module Collavre
  module Topics
    # Explains a Topic.primary_agent_rejection symbol to an MCP caller.
    #
    # The two reasons need different advice and the difference matters: sharing
    # the creative fixes a missing-permission rejection, while a Claude Channel
    # session agent stays confined to its own session topic no matter what is
    # shared. Telling a caller to share in that second case sends it after a fix
    # that cannot work — the same distinction TopicsController draws for humans.
    module PinRejection
      module_function

      def message(agent, rejection)
        if rejection == :session_agent_outside_session_topic
          "#{agent.display_name} is a session agent and can only be pinned to its own session topic."
        else
          "#{agent.display_name} has no feedback permission on this creative, so it cannot be pinned. " \
            "Share the creative with the agent at feedback or higher first."
        end
      end
    end
  end
end
