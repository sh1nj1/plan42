module Collavre
  class Comment < ApplicationRecord
    module Broadcastable
      extend ActiveSupport::Concern

      # The desktop and mobile inbox badge DOM ids kept in sync in real time.
      INBOX_BADGE_TARGETS = %w[desktop-inbox-badge mobile-inbox-badge].freeze

      included do
        after_create_commit :broadcast_create
        after_update_commit :broadcast_update
        after_destroy_commit :broadcast_destroy
        # Use after_commit with on: to avoid Rails callback deduplication.
        # Registering the same method via both after_create_commit and
        # after_destroy_commit causes the later registration to silently
        # overwrite the earlier one.
        after_commit :broadcast_badges, on: [ :create, :destroy ]
      end

      module ClassMethods
        # The one enqueue seam for badge recomputation. Every write path that
        # invalidates a badge goes through here rather than calling
        # #broadcast_badges directly, so "badges are recounted off the request"
        # holds for all of them and can't drift back one caller at a time.
        # #broadcast_badges itself stays synchronous: the job — and the tests
        # that pin the arithmetic — need a place that just computes.
        def broadcast_badges_later(creative)
          return unless creative

          CommentBadgesBroadcastJob.perform_later(creative.id)
        end

        def broadcast_badges(creative)
          origin = creative.effective_origin
          users = [ origin.user ].compact + origin.all_shared_users(:feedback).map(&:user)
          users.compact!
          users.uniq!
          return if users.empty?

          user_ids = users.map(&:id)

          pointers = CommentReadPointer.where(user_id: user_ids, creative: origin).index_by(&:user_id)
          present_user_ids = CommentPresenceStore.list(origin.id)

          public_count = origin.comments.public_only.count
          private_counts = origin.comments
            .where(private: true, user_id: user_ids)
            .group(:user_id)
            .count

          last_read_ids = pointers.transform_values { |p| p.last_read_comment_id || 0 }

          unread_public_by_threshold = {}
          # Include 0 for users without a read pointer (never opened chat)
          all_thresholds = (last_read_ids.values + [ 0 ]).uniq
          all_thresholds.each do |threshold|
            unread_public_by_threshold[threshold] = origin.comments
              .where(private: false)
              .where("comments.id > ?", threshold)
              .count
          end

          unread_private_counts = {}
          user_ids.each do |uid|
            threshold = last_read_ids[uid] || 0
            unread_private_counts[uid] = origin.comments
              .where(private: true, user_id: uid)
              .where("comments.id > ?", threshold)
              .count
          end

          users.each do |u|
            user_private_count = private_counts[u.id] || 0
            total_count = public_count + user_private_count

            threshold = last_read_ids[u.id] || 0
            unread_public = unread_public_by_threshold[threshold] || 0
            unread_private = unread_private_counts[u.id] || 0
            unread_count = unread_public + unread_private

            unread_count = 0 if present_user_ids.include?(u.id)

            Turbo::StreamsChannel.broadcast_replace_to(
              [ u, origin, :comment_badge ],
              target: "comment-badge-#{origin.id}",
              partial: "inbox/badge_component/count",
              locals: {
                count: unread_count,
                badge_id: "comment-badge-#{origin.id}",
                show_zero: total_count.positive?
              }
            )

            # Also update the global inbox badge when the creative is an inbox
            broadcast_inbox_badge(origin, u, count: unread_count) if origin.inbox?
          end
        end

        def broadcast_badge(creative, user)
          origin = creative.effective_origin
          visible_comments = origin.comments.visible_to(user)
          comments_count = visible_comments.count
          pointer = CommentReadPointer.find_by(user: user, creative: origin)
          last_read_id = pointer&.last_read_comment_id
          unread_scope = last_read_id ? visible_comments.where("comments.id > ?", last_read_id) : visible_comments
          unread_count = unread_scope.count
          unread_count = 0 if CommentPresenceStore.list(origin.id).include?(user.id)
          Turbo::StreamsChannel.broadcast_replace_to(
            [ user, origin, :comment_badge ],
            target: "comment-badge-#{origin.id}",
            partial: "inbox/badge_component/count",
            locals: {
              count: unread_count,
              badge_id: "comment-badge-#{origin.id}",
              show_zero: comments_count.positive?
            }
          )

          # Also update the global inbox badge when the creative is an inbox
          broadcast_inbox_badge(origin, user, count: unread_count) if origin.inbox?
        end

        # Broadcast updated inbox badge count to the user's global inbox badge.
        # Called when inbox comments are created (via Notifiable) and when the
        # user reads their inbox (via read pointer update / presence unsubscribe).
        # Accepts an optional pre-computed count to avoid duplicate queries.
        def broadcast_inbox_badge(inbox_creative, owner, count: nil)
          return unless inbox_creative && owner

          count ||= inbox_badge_count(inbox_creative, owner)

          INBOX_BADGE_TARGETS.each do |target_id|
            Turbo::StreamsChannel.broadcast_replace_to(
              [ "inbox", owner ],
              target: target_id,
              partial: "inbox/badge_component/count",
              locals: inbox_badge_locals(count, target_id)
            )
          end
        end

        # Render the same inbox badge replacements as a Turbo Stream string so a
        # channel can transmit them straight to its own confirmed subscriber
        # (see InboxBadgeChannel), instead of re-broadcasting to the sibling
        # ["inbox", user] stream and risking a reconnect race. Returns nil when
        # there is nothing to render.
        def inbox_badge_turbo_stream(inbox_creative, owner, count: nil)
          return unless inbox_creative && owner

          count ||= inbox_badge_count(inbox_creative, owner)

          INBOX_BADGE_TARGETS.map do |target_id|
            Turbo::StreamsChannel.turbo_stream_action_tag(
              :replace,
              target: target_id,
              template: ApplicationController.render(
                partial: "inbox/badge_component/count",
                formats: [ :html ],
                locals: inbox_badge_locals(count, target_id)
              )
            )
          end.join.html_safe
        end

        private

        # Inbox badge count when no caller-supplied count is available (e.g. the
        # reconnect snapshot in InboxBadgeChannel). Mirrors broadcast_badge's
        # suppression: a user actively viewing the inbox (present in
        # CommentPresenceStore) sees 0, so a reconnect can't repaint unread items
        # over the suppressed badge.
        def inbox_badge_count(inbox_creative, owner)
          return 0 if CommentPresenceStore.list(inbox_creative.id).include?(owner.id)

          Collavre::Inbox::BadgeComponent.new(user: owner, creative: inbox_creative).count
        end

        def inbox_badge_locals(count, target_id)
          { count: count, badge_id: target_id, show_zero: false }
        end
      end

      private

      def broadcast_create
        return if private?
        broadcast_append_later_to([ creative, :comments ], target: "comments-list", partial: "collavre/comments/comment")
      end

      def broadcast_update
        return if private?
        broadcast_replace_later_to([ creative, :comments ], partial: "collavre/comments/comment")
      end

      def broadcast_destroy
        return if private? || !creative
        broadcast_remove_to([ creative, :comments ])
      end

      def broadcast_badges
        return unless creative
        self.class.broadcast_badges_later(creative)
      end
    end
  end
end
