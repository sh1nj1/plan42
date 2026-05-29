# frozen_string_literal: true

module Collavre
  module Tools
    # Topic write authorization for MCP tool services. Mirrors
    # CreativePermissionGuard#require_creative_write! but is callable outside a
    # controller request. Attaching a channel injects external messages into a
    # topic, so it is a write-equivalent mutation — restrict to users with
    # write permission on the topic's effective_origin creative.
    module TopicAuthorizer
      module_function

      def authorize_write!(topic, user: Collavre::Current.user)
        creative = topic.creative&.effective_origin
        raise ArgumentError, "Topic has no creative" unless creative
        return if creative.user == user
        return if user && creative.has_permission?(user, :write)

        raise Collavre::Tools::PermissionDeniedError,
          "No write permission on topic #{topic.id}"
      end
    end
  end
end
