module Collavre
  class Comment < ApplicationRecord
    module Notifiable
      extend ActiveSupport::Concern

      NOTIFICATION_RELEVANT_ATTRIBUTES = %w[
        action approver_id content creative_id private topic_id user_id
      ].freeze

      included do
        before_update :advance_notification_revision, if: :notification_relevant_change?
        after_create_commit :enqueue_create_notifications, if: :notification_eligible_on_create?
      end

      def mentioned_users
        return Collavre.user_class.none unless user

        emails = mentioned_emails - [ user.email.downcase ]
        names = mentioned_names - [ user.name.downcase ]
        mentionable_users = Collavre.user_class.mentionable_for(creative.effective_origin)

        scope = Collavre.user_class.none
        scope = scope.or(mentionable_users.where(email: emails)) if emails.any?
        scope = scope.or(mentionable_users.where("LOWER(name) IN (?)", names)) if names.any?
        scope
      end

      def notification_event
        {
          "creative_id" => creative_id,
          "regular_notification" => regular_notification_eligible?,
          "approval_notification" => approval_notification_eligible?,
          "revision" => notification_revision
        }
      end

      # Notify users about a completed AI streaming message without holding up
      # response finalization. Placeholder notifications are skipped on create.
      def notify_ai_completion
        return unless user&.ai_user?
        return if private? || suppress_inbox_notification?

        CommentNotificationJob.perform_later(id, "ai_completion", notification_event)
      rescue StandardError => e
        Rails.logger.error("[notify_ai_completion] Failed for comment #{id}: #{e.message}")
      end

      def deliver_notifications(kind, event)
        event = event.stringify_keys
        return unless event["creative_id"] == creative_id
        return unless event["revision"] == notification_revision

        case kind.to_s
        when "created"
          if event["regular_notification"]
            notify_write_users("created")
            notify_mentions("created")
          end
          notify_approver("created") if event["approval_notification"]
        when "ai_completion"
          return unless user&.ai_user?
          return if private? || suppress_inbox_notification?

          notify_write_users("ai_completion")
          notify_mentions("ai_completion")
        else
          raise ArgumentError, "Unknown comment notification kind: #{kind}"
        end
      end

      private

      def notification_relevant_change?
        NOTIFICATION_RELEVANT_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
      end

      def advance_notification_revision
        self.notification_revision += 1
      end

      def notification_eligible_on_create?
        regular_notification_eligible? || approval_notification_eligible?
      end

      def regular_notification_eligible?
        !private? && !streaming_placeholder? && !suppress_inbox_notification?
      end

      def approval_notification_eligible?
        approver.present? && approval_action? && !creative&.inbox?
      end

      def enqueue_create_notifications
        CommentNotificationJob.perform_later(id, "created", notification_event)
      end

      def create_inbox_comment(owner, key, params = {}, delivery_key: nil)
        inbox_creative = Creative.inbox_for(owner)
        return unless inbox_creative

        system_topic = inbox_creative.system_topic(fallback_user: owner)
        msg = I18n.t(key, **params.symbolize_keys, locale: owner.locale || "en")
        attributes = {
          creative: inbox_creative,
          topic: system_topic,
          content: msg,
          user: nil,
          skip_default_user: true,
          quoted_comment: self
        }

        comment = if delivery_key
          Comment.create_or_find_by!(notification_key: delivery_key) do |candidate|
            candidate.assign_attributes(attributes)
          end
        else
          Comment.create!(attributes)
        end

        return comment unless comment.previously_new_record?

        PushNotificationJob.perform_later(owner.id, message: msg, link: inbox_comment_link)
        comment
      rescue StandardError => e
        Rails.logger.error("[Notifiable] Failed to create inbox comment for user #{owner.id}: #{e.message}")
        raise
      end

      # Keep legacy method for backward compatibility during transition
      def create_inbox_item(owner, key, params = {})
        create_inbox_comment(owner, key, params)
      end

      def creative_markdown_link(target_creative = creative)
        path = Collavre::Engine.routes.url_helpers.creative_path(target_creative, open_comments: true)
        "[#{target_creative.creative_snippet}](#{path})"
      end

      def inbox_comment_link
        Collavre::Engine.routes.url_helpers.creative_comment_url(
          creative,
          self,
          Rails.application.config.action_mailer.default_url_options
        )
      end

      def streaming_placeholder?
        user&.ai_user? && content == STREAMING_PLACEHOLDER_CONTENT
      end

      def mentioned_emails
        return [] unless content

        content.scan(/@([\w.\-+]+@[a-zA-Z0-9\-.]+\.[a-zA-Z]{2,})/)
               .flatten
               .map(&:downcase)
               .uniq
      end

      def mentioned_names
        return [] unless content

        content.scan(/@([^:]+):/)
               .flatten
               .map(&:downcase)
               .uniq
      end

      # Build the list of write-access recipients minus the comment author,
      # mentioned users, and users currently present on the creative.
      def notification_recipients
        base_creative = creative.effective_origin
        present_ids = CommentPresenceStore.list(base_creative.id)

        recipients = base_creative.all_shared_users(:write).map(&:user)
        recipients << base_creative.user
        recipients.compact!
        recipients.uniq!
        recipients.delete(user)
        recipients -= mentioned_users.to_a
        recipients.reject! { |recipient| present_ids.include?(recipient.id) }
        recipients
      end

      def notify_write_users(kind)
        return unless user

        notification_recipients.each do |recipient|
          create_inbox_comment(
            recipient,
            "inbox.comment_added",
            {
              user: user.display_name,
              comment: content,
              creative: creative_markdown_link
            },
            delivery_key: notification_delivery_key(kind, "write", recipient)
          )
        end
      end

      def notify_mentions(kind)
        mentioned_users.each do |mentioned|
          create_inbox_comment(
            mentioned,
            "inbox.user_mentioned",
            {
              user: user.display_name,
              comment: content,
              creative: creative_markdown_link
            },
            delivery_key: notification_delivery_key(kind, "mention", mentioned)
          )
        end
      end

      # #1301 made every inbox topic EXCEPT System dispatch like a normal topic;
      # the alarm stream follows suit. Suppress notifications ONLY for the System
      # topic itself (its system-authored notices must not cascade into more
      # notices — a loop). Inbox#Main and other inbox topics notify normally, so
      # an agent reply there reaches the absent owner. Mirrors the dispatch gate
      # in Comment#dispatch_to_orchestration.
      def suppress_inbox_notification?
        creative&.inbox? && inbox_system_topic?
      end

      def notification_delivery_key(kind, recipient_type, recipient)
        "comment:#{id}:#{notification_revision}:#{kind}:#{recipient_type}:recipient:#{recipient.id}"
      end

      def notify_approver(kind)
        return unless approver.present? && approval_action?
        return if approver == user
        return if creative&.inbox? # Don't notify about inbox comments

        create_inbox_comment(
          approver,
          "inbox.approval_requested",
          {
            user: user&.display_name,
            tool_name: parsed_action_tool_name,
            creative: creative_markdown_link
          },
          delivery_key: notification_delivery_key(kind, "approver", approver)
        )
      end
    end
  end
end
