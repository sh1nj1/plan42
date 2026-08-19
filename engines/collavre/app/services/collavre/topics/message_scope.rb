# frozen_string_literal: true

module Collavre
  module Topics
    # The one definition of "the messages of a topic" that the read tools share,
    # so a count reported by topic_list and a page returned by topic_messages
    # can never describe different sets.
    module MessageScope
      module_function

      # include_system: false is the default because the caller is almost always
      # summarizing a conversation. Authorless rows are the timeline's
      # furniture — "⏳" concurrency notices, channel announcements — and
      # approval-action rows are the approval surface, which
      # Comment.without_approval_action already keeps away from agents
      # everywhere else. Leaving them in would spend the caller's character
      # budget on text nobody wrote.
      #
      # visible_to is applied unconditionally: a private comment belongs to its
      # author and approver, and a tool must not be the way around that.
      #
      # max_message_id freezes the window. Newest-first offset pagination drifts
      # when the topic is live — a message posted between page 1 and page 2
      # shifts every later row down one, so the caller re-reads one message and
      # never sees another. Passing back the newest_message_id from the first
      # page pins every subsequent page to the same snapshot.
      def for(topic, user:, include_system: false, max_message_id: nil)
        for_ids([ topic.id ], user: user, include_system: include_system, max_message_id: max_message_id)
      end

      # Same rules across many topics at once, for the grouped totals query.
      def for_ids(topic_ids, user:, include_system: false, max_message_id: nil)
        scope = Comment.where(topic_id: topic_ids).visible_to(user)
        scope = scope.without_approval_action.where.not(user_id: nil) unless include_system
        scope = scope.where("comments.id <= ?", max_message_id) if max_message_id
        scope
      end
    end
  end
end
