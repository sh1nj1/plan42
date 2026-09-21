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

          badges_by_user_id = Creatives::CommentBadgeIndex.for_users(origin: origin, users: users)

          users.each do |u|
            badge = badges_by_user_id.fetch(u.id)

            Turbo::StreamsChannel.broadcast_replace_to(
              [ u, origin, :comment_badge ],
              target: "comment-badge-#{origin.id}",
              partial: "inbox/badge_component/count",
              locals: {
                count: badge.unread_count,
                badge_id: "comment-badge-#{origin.id}",
                show_zero: badge.visible_comments
              }
            )

            # Also update the global inbox badge when the creative is an inbox
            broadcast_inbox_badge(origin, u, count: badge.unread_count) if origin.inbox?
          end
        end

        def broadcast_badge(creative, user)
          origin = creative.effective_origin
          badge_index = Creatives::CommentBadgeIndex.new(user: user)
          badge_index.index([ origin ])
          unread_count = badge_index.unread_count_for(origin)
          Turbo::StreamsChannel.broadcast_replace_to(
            [ user, origin, :comment_badge ],
            target: "comment-badge-#{origin.id}",
            partial: "inbox/badge_component/count",
            locals: {
              count: unread_count,
              badge_id: "comment-badge-#{origin.id}",
              show_zero: badge_index.visible_comments?(origin)
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
