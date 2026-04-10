# frozen_string_literal: true

module Collavre
  class AgentChannel < ApplicationCable::Channel
    # Subscribes to a topic's agent stream for real-time comment notifications.
    # Params: topic_id (required)
    def subscribed
      return reject unless params[:topic_id].present? && current_user

      @topic = Topic.find_by(id: params[:topic_id])
      return reject unless @topic

      creative = @topic.creative&.effective_origin
      return reject unless creative&.has_permission?(current_user, :read)

      stream_from stream_name
    end

    def unsubscribed
      # No cleanup needed
    end

    # Broadcast a comment event to the agent stream for a topic.
    def self.broadcast_comment(topic_id, comment)
      ActionCable.server.broadcast(
        "agent:topic:#{topic_id}",
        {
          type: "comment",
          comment: {
            id: comment.id,
            content: comment.content,
            author_id: comment.user_id,
            author_name: comment.user&.display_name,
            topic_id: comment.topic_id,
            creative_id: comment.creative_id,
            created_at: comment.created_at.iso8601
          }
        }
      )
    end

    private

    def stream_name
      "agent:topic:#{@topic.id}"
    end
  end
end
