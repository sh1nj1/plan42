# frozen_string_literal: true

module CollavreLinear
  # Deletes the mirrored Linear comment when a Collavre::Comment is destroyed.
  #
  #   CollavreLinear::OutboundCommentDeleteJob.perform_later(comment_link.id)
  #
  # Keyed on the CommentLink id (not the comment id): the local comment is already
  # hard-deleted by the time this runs, so the link is the only surviving handle
  # on the Linear comment id. Idempotent: a re-run after the link is torn down
  # finds nothing and does nothing.
  class OutboundCommentDeleteJob < ApplicationJob
    queue_as :default

    retry_on CollavreLinear::Client::Error, wait: :polynomially_longer, attempts: 5

    def perform(comment_link_id)
      comment_link = CollavreLinear::CommentLink.find_by(id: comment_link_id)
      return unless comment_link

      account = comment_link.issue_link.project_link.account
      return unless account

      CollavreLinear::Client.new(account).delete_comment(comment_link.linear_comment_id)
      comment_link.destroy
    end
  end
end
