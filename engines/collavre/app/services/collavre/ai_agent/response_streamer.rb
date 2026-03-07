# frozen_string_literal: true

module Collavre
  module AiAgent
    # Handles streaming response content from AI to comments.
    # Manages throttling, broadcasting, and placeholder cleanup.
    class ResponseStreamer
      # Minimum interval (in seconds) between streaming updates to avoid excessive DB writes
      STREAM_THROTTLE_INTERVAL = 0.1

      def initialize(reply_comment:, creative:)
        @reply_comment = reply_comment
        @creative = creative
        @content = ""
        @last_broadcast_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Append delta content and broadcast if throttle interval passed
      def append(delta)
        @content += delta

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @reply_comment && (now - @last_broadcast_at) >= STREAM_THROTTLE_INTERVAL
          update_and_broadcast(streaming: true)
          @last_broadcast_at = now
        end
      end

      # Get accumulated content
      def content
        @content
      end

      # Finalize streaming by broadcasting final update
      def finalize
        update_and_broadcast(streaming: false) if @reply_comment && @content.present?
      end

      # Check if there's content accumulated
      def content_present?
        @content.present?
      end

      private

      def update_and_broadcast(streaming:)
        @reply_comment.update_column(:content, @content)
        @reply_comment.broadcast_update_to(
          [ @reply_comment.creative, :comments ],
          partial: "collavre/comments/comment",
          locals: { comment: @reply_comment, streaming: streaming }
        )
      end
    end
  end
end
