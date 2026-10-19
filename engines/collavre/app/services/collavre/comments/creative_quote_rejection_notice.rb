# frozen_string_literal: true

module Collavre
  module Comments
    # Leaves a system line in the review's topic when the user rejects a
    # document-mode review draft, so the agent sees the rejection in its chat
    # history when the user follows up with what to change.
    class CreativeQuoteRejectionNotice
      def self.call(change_set)
        new(change_set).call
      end

      def initialize(change_set)
        @change_set = change_set
      end

      def call
        trigger = trigger_comment
        return unless trigger&.creative_review_message? && trigger.quoted_creative

        Comment.create!(
          creative: trigger.creative, topic_id: trigger.topic_id, user: nil, skip_default_user: true,
          skip_dispatch: true,
          content: I18n.t("collavre.comments.creative_quote.rejected_notice",
                          title: trigger.quoted_creative.creative_snippet)
        )
      end

      private

      def trigger_comment
        id = @change_set.task&.trigger_comment_id
        Comment.find_by(id: id) if id
      end
    end
  end
end
