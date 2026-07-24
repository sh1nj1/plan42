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

      updated = Comment
        .where(
          id: comment_id,
          content: expected_content,
          notification_revision: expected_revision
        )
        .update_all(content: formatted_content, updated_at: Time.current)
      return unless updated == 1

      comment.reload
      return if comment.private?

      comment.broadcast_replace_later_to(
        [ comment.creative, :comments ],
        partial: "collavre/comments/comment"
      )
    end
  end
end
