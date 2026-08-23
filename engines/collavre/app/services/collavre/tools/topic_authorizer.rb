# frozen_string_literal: true

module Collavre
  module Tools
    # Topic authorization for MCP tool services. Mirrors
    # CreativePermissionGuard's require_creative_{read,write,admin}! but is
    # callable outside a controller request. Every check resolves the topic's
    # effective_origin creative first, because that is where shares live — a
    # linked creative carries none of its own.
    #
    # The owner short-circuit matches CreativePermissionGuard: an owner can hold
    # no explicit share on their own creative, so has_permission? alone would
    # lock them out of their own topics.
    module TopicAuthorizer
      module_function

      # Reading a topic's messages exposes every participant's words, so it is
      # gated at :read — the same level the creative's own body needs.
      def authorize_read!(topic, user: Collavre::Current.user)
        authorize!(topic, :read, user: user)
      end

      # Posting a message is the topic equivalent of commenting through
      # CommentsController, so it uses the same feedback permission floor.
      def authorize_feedback!(topic, user: Collavre::Current.user)
        authorize!(topic, :feedback, user: user)
      end

      # Attaching a channel injects external messages into a topic, and creating
      # or archiving one restructures where conversation lands, so both are
      # write-equivalent mutations.
      def authorize_write!(topic, user: Collavre::Current.user)
        authorize!(topic, :write, user: user)
      end

      # Renaming a topic rewrites a name other members' links and habits point
      # at, so TopicsController gates it at :admin. Tools must not be the softer
      # door onto the same mutation.
      def authorize_admin!(topic, user: Collavre::Current.user)
        authorize!(topic, :admin, user: user)
      end

      # Topic creation has no topic to authorize against yet, so the creative is
      # the subject. Kept here so every topic-shaped permission decision reads
      # from one place.
      def authorize_creative!(creative, level, user: Collavre::Current.user)
        origin = creative&.effective_origin
        raise ArgumentError, "Creative is required" unless origin
        return if origin.user == user
        return if user && origin.has_permission?(user, level)

        raise Collavre::Tools::PermissionDeniedError,
          "No #{level} permission on creative #{origin.id}"
      end

      def authorize!(topic, level, user: Collavre::Current.user)
        creative = topic.creative&.effective_origin
        raise ArgumentError, "Topic has no creative" unless creative
        return if creative.user == user
        return if user && creative.has_permission?(user, level)

        raise Collavre::Tools::PermissionDeniedError,
          "No #{level} permission on topic #{topic.id}"
      end

      # True when the user may read the topic. Used by the multi-topic read
      # tools, which report an inaccessible topic as a per-topic error entry
      # rather than failing the whole call — one unreadable id in a batch of
      # three should not discard the two that worked.
      def readable?(topic, user: Collavre::Current.user)
        authorize_read!(topic, user: user)
        true
      rescue Collavre::Tools::PermissionDeniedError, ArgumentError
        false
      end
    end
  end
end
