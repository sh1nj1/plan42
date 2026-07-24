# frozen_string_literal: true

module Collavre
  class CommentLinkPreviewJob < ApplicationJob
    queue_as :default

    retry_on StandardError, wait: :polynomially_longer, attempts: 3
    discard_on ActiveRecord::RecordNotFound

    def perform(comment_id, expected_content, expected_revision)
      comment = Comment.find(comment_id)
      return unless comment.content == expected_content
      return unless comment.notification_revision == expected_revision

      formatted_content = CommentLinkFormatter.new(expected_content).format
      return if formatted_content == expected_content

      Comment.transaction do
        comment = Comment.lock.find(comment_id)
        return unless comment.content == expected_content
        return unless comment.notification_revision == expected_revision

        # This is a derived representation of the same logical comment revision.
        # Save normally so every Comment after_update_commit integration observes
        # the formatted content, while suppressing only notification revision
        # advancement and another preview job.
        comment.skip_link_preview = true
        comment.skip_notification_revision = true
        comment.update!(content: formatted_content)
      end
    end
  end
end
