# frozen_string_literal: true

module Collavre
  # Handles inline replies from the inbox System topic.
  # When a user sends a message in their inbox's #System topic,
  # this service finds the most recent notification (alarm) and
  # cross-posts the reply to the original creative/topic that
  # the notification was about.
  class InboxReplyService
    def self.call(comment)
      new(comment).call
    end

    def initialize(comment)
      @comment = comment
      @creative = comment.creative
    end

    def call
      return unless eligible?

      original = find_original_comment
      return unless original

      cross_post(original)
    end

    private

    def eligible?
      @creative.inbox? &&
        @comment.topic&.name == Creative::SYSTEM_TOPIC_NAME &&
        @comment.user_id.present? &&
        !@comment.user&.ai_user?
    end

    # Find the most recent system notification in this topic before the user's comment.
    # System notifications have user_id: nil and often a quoted_comment pointing
    # to the original comment that triggered the notification.
    def find_original_comment
      latest_alarm = @creative.comments
        .where(topic: @comment.topic, user_id: nil)
        .where("comments.id < ?", @comment.id)
        .order(created_at: :desc)
        .first

      return nil unless latest_alarm

      latest_alarm.quoted_comment
    end

    def cross_post(original)
      Comment.create!(
        creative: original.creative,
        topic: original.topic,
        content: @comment.content,
        user: @comment.user,
        quoted_comment: original,
        private: false
      )
    rescue StandardError => e
      Rails.logger.error(
        "[InboxReplyService] Failed to cross-post comment #{@comment.id}: " \
        "#{e.class} #{e.message}"
      )
      nil
    end
  end
end
