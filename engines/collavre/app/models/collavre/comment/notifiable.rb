module Collavre
  class Comment < ApplicationRecord
    module Notifiable
      extend ActiveSupport::Concern

      included do
        after_create_commit :notify_write_users, :notify_mentions, :notify_approver
      end

      def mentioned_users
        return Collavre.user_class.none unless user
        emails = mentioned_emails - [ user.email.downcase ]
        names = mentioned_names - [ user.name.downcase ]

        origin = creative.effective_origin
        mentionable_users = Collavre.user_class.mentionable_for(origin)

        scope = Collavre.user_class.none
        scope = scope.or(mentionable_users.where(email: emails)) if emails.any?
        scope = scope.or(mentionable_users.where("LOWER(name) IN (?)", names)) if names.any?
        scope
      end

      # Notify users about a completed AI streaming message.
      # Called from ResponseFinalizer after placeholder is updated with final content.
      # Sends both write-user and mention notifications that were skipped at placeholder creation.
      # Errors are rescued to avoid breaking the finalization flow.
      def notify_ai_completion
        return unless user&.ai_user?
        return if private?

        notify_ai_write_users
        notify_ai_mentions
      rescue StandardError => e
        Rails.logger.error("[notify_ai_completion] Failed for comment #{id}: #{e.message}")
      end

      private

      def create_inbox_comment(owner, key, params = {})
        inbox_creative = Creative.inbox_for(owner)
        return unless inbox_creative

        system_topic = inbox_creative.system_topic(fallback_user: owner)
        msg = I18n.t(key, **params.symbolize_keys, locale: owner.locale || "en")

        comment = Comment.create!(
          creative: inbox_creative,
          topic: system_topic,
          content: msg,
          user: nil,
          skip_default_user: true,
          quoted_comment: self
        )

        Comment.broadcast_inbox_badge(inbox_creative, owner)
        PushNotificationJob.perform_later(owner.id, message: msg, link: inbox_comment_link)
        comment
      rescue StandardError => e
        Rails.logger.error("[Notifiable] Failed to create inbox comment for user #{owner.id}: #{e.message}")
        nil
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
        recipients.reject! { |u| present_ids.include?(u.id) }
        recipients
      end

      def notify_write_users
        return if private? || !user
        return if streaming_placeholder?
        return if suppress_inbox_notification? # only the System topic is the alarm stream
        notification_recipients.each do |recipient|
          create_inbox_comment(
            recipient,
            "inbox.comment_added",
            { user: user.display_name, comment: content, creative: creative_markdown_link }
          )
        end
      end

      def notify_mentions
        return if private?
        return if streaming_placeholder?
        return if suppress_inbox_notification? # only the System topic is the alarm stream
        notify_mentioned_users
      end

      def notify_mentioned_users
        mentioned_users.each do |mentioned|
          create_inbox_comment(
            mentioned,
            "inbox.user_mentioned",
            { user: user.display_name, comment: content, creative: creative_markdown_link }
          )
        end
      end

      def notify_ai_write_users
        return if suppress_inbox_notification? # only the System topic is the alarm stream
        notification_recipients.each do |recipient|
          create_inbox_comment(
            recipient,
            "inbox.comment_added",
            { user: user.display_name, comment: content, creative: creative_markdown_link }
          )
        end
      end

      def notify_ai_mentions
        return if suppress_inbox_notification? # only the System topic is the alarm stream
        notify_mentioned_users
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

      def notify_approver
        return unless approver.present? && approval_action?
        return if approver == user
        return if creative&.inbox? # Don't notify about inbox comments

        create_inbox_comment(
          approver,
          "inbox.approval_requested",
          { user: user&.display_name, tool_name: parsed_action_tool_name, creative: creative_markdown_link }
        )
      end
    end
  end
end
