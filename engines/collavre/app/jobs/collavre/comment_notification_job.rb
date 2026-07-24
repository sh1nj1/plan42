# frozen_string_literal: true

module Collavre
  class CommentNotificationJob < ApplicationJob
    queue_as :default

    retry_on StandardError, wait: :polynomially_longer, attempts: 3
    discard_on ActiveRecord::RecordNotFound

    def perform(comment_id, kind, event)
      Comment.find(comment_id).deliver_notifications(kind, event)
    end
  end
end
