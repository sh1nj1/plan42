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
      # Uses the same logic as notify_write_users but runs on update (not create).
      def notify_ai_completion
        return unless user&.ai_user?

        base_creative = creative.effective_origin
        present_ids = CommentPresenceStore.list(base_creative.id)

        recipients = base_creative.all_shared_users(:write).map(&:user)
        recipients << base_creative.user
        recipients.compact!
        recipients.uniq!
        recipients.delete(user)
        recipients -= mentioned_users.to_a
        recipients.reject! { |u| present_ids.include?(u.id) }

        recipients.each do |recipient|
          create_inbox_item(
            recipient,
            "inbox.comment_added",
            { user: user.display_name, comment: content, creative: creative_snippet }
          )
        end
      end

      private

      def create_inbox_item(owner, key, params = {})
        origin = creative&.effective_origin
        metadata = params.to_h.stringify_keys
        metadata["comment_id"] = id
        metadata["creative_id"] = origin&.id

        InboxItem.create!(
          owner: owner,
          message_key: key,
          message_params: metadata,
          comment: self,
          creative: origin,
          link: Collavre::Engine.routes.url_helpers.creative_comment_url(
            creative,
            self,
            Rails.application.config.action_mailer.default_url_options
          )
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

      def notify_write_users
        return if private? || !user
        return if streaming_placeholder?
        base_creative = creative.effective_origin
        present_ids = CommentPresenceStore.list(base_creative.id)
        recipients = base_creative.all_shared_users(:write).map(&:user)
        recipients << base_creative.user
        recipients.compact!
        recipients.uniq!
        recipients.delete(user)
        recipients -= mentioned_users.to_a
        recipients.reject! { |u| present_ids.include?(u.id) }
        recipients.each do |recipient|
          create_inbox_item(
            recipient,
            "inbox.comment_added",
            { user: user.display_name, comment: content, creative: creative_snippet }
          )
        end
      end

      def notify_mentions
        return if private?
        return if streaming_placeholder?
        mentioned_users.each do |mentioned|
          create_inbox_item(
            mentioned,
            "inbox.user_mentioned",
            { user: user.display_name, comment: content, creative: creative_snippet }
          )
        end
      end

      def notify_approver
        return unless approver.present? && action.present?
        return if approver == user

        create_inbox_item(
          approver,
          "inbox.approval_requested",
          { user: user&.display_name, tool_name: parsed_action_tool_name, creative: creative_snippet }
        )
      end
    end
  end
end
