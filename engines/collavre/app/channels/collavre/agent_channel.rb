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

    # Broadcast an arbitrary payload to a topic's agent stream.
    def self.broadcast_to_topic(topic_id, payload)
      ActionCable.server.broadcast("agent:topic:#{topic_id}", payload)
    end

    private

    def stream_name
      "agent:topic:#{@topic.id}"
    end
  end
end
