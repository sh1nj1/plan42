# frozen_string_literal: true

module Collavre
  module Topics
    # The one definition of "the messages of a topic" that the read tools share,
    # so a count reported by topic_list and a page returned by topic_messages
    # can never describe different sets.
    module MessageScope
      module_function

      # include_system: false is the default because the caller is almost always
      # summarizing a conversation, and authorless rows are the timeline's
      # furniture — "⏳" concurrency notices, channel announcements. Leaving
      # them in would spend the caller's character budget on text nobody wrote.
      #
      # without_approval_action is NOT part of that switch. Approval-surface
      # rows are excluded unconditionally, because Comment.without_approval_action
      # carries an invariant these tools do not get to opt out of: an approval
      # prompt must never reach an agent as history or trigger context. Every
      # other agent-context query in the engine applies it the same way, and a
      # read tool is exactly the back door that invariant exists to close.
      #
      # visible_to is applied unconditionally for the same reason: a private
      # comment belongs to its author and approver, and a tool must not be the
      # way around that.
      #
      # max_message_id excludes rows created after the first page. The topic
      # assignment anchor excludes older rows moved in after that page, while
      # MessagePage's keyset cursor lets rows leave without shifting unread
      # survivors ahead of a numeric offset.
      def for(topic, user:, include_system: false, max_message_id: nil, topic_assigned_before: nil)
        for_topics(
          [ topic ], user: user, include_system: include_system,
          max_message_id: max_message_id, topic_assigned_before: topic_assigned_before
        )
      end

      # Pair every topic id with the creative that was authorized. TopicMove
      # preserves the topic id while relocating all of its comments, so an
      # id-only query could read the destination creative after the permission
      # check. The exact pair also avoids cross-topic matches in batch totals.
      def for_topics(topics, user:, include_system: false, max_message_id: nil, topic_assigned_before: nil)
        membership = topic_membership(topics)
        return Comment.none unless membership

        scope = Comment.where(membership).visible_to(user).without_approval_action
        scope = scope.where.not(user_id: nil) unless include_system
        scope = scope.where("comments.id <= ?", max_message_id) if max_message_id
        scope = scope.where("comments.topic_assigned_at <= ?", topic_assigned_before) if topic_assigned_before
        scope
      end

      def topic_membership(topics)
        table = Comment.arel_table
        Array(topics).map do |topic|
          table[:topic_id].eq(topic.id).and(table[:creative_id].eq(topic.creative_id))
        end.reduce { |combined, pair| combined.or(pair) }
      end
    end
  end
end
