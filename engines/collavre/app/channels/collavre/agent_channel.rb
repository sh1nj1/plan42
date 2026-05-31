# frozen_string_literal: true

module Collavre
  class AgentChannel < ApplicationCable::Channel
    # Subscribes to an agent stream for real-time dispatch notifications.
    # Accepts either:
    #   - agent_id: per-agent stream — used by MCP plugin clients (Claude
    #     Channel) so they receive every dispatch routed to the agent, no
    #     matter which topic triggered it. Authorized by created_by ownership.
    #   - topic_id: per-topic stream — legacy/UI listeners scoped to one topic.
    def subscribed
      return reject unless current_user

      if params[:agent_id].present?
        subscribe_to_agent_stream
      elsif params[:topic_id].present?
        subscribe_to_topic_stream
      else
        reject
      end
    end

    # When the MCP process crashes or the WebSocket drops before the plugin
    # can call DELETE /api/v1/agent/:id, the per-session Claude Channel agent
    # would otherwise stay matchable (routing_expression: "true") and any
    # future comment on a creative still shared with it would dispatch into
    # an empty stream — delegated work that only clears via stuck recovery.
    # Mark the session agent offline here so Orchestration::Matcher stops
    # selecting it; subscribe_to_agent_stream restores routing on reconnect.
    def unsubscribed
      return unless @session_agent

      @session_agent.reload
      if @session_agent.routing_expression.present?
        @session_agent.update_column(:routing_expression, nil)
      end
    rescue ActiveRecord::RecordNotFound
      # Agent deleted between subscribe and unsubscribe — nothing to clear.
    end

    # Broadcast an arbitrary payload to a topic's agent stream.
    def self.broadcast_to_topic(topic_id, payload)
      ActionCable.server.broadcast("agent:topic:#{topic_id}", payload)
    end

    # Broadcast to a per-agent stream so the agent's MCP plugin receives the
    # dispatch regardless of which topic triggered it.
    def self.broadcast_to_agent(agent_id, payload)
      ActionCable.server.broadcast("agent:user:#{agent_id}", payload)
    end

    private

    def subscribe_to_topic_stream
      @topic = Topic.find_by(id: params[:topic_id])
      return reject unless @topic

      creative = @topic.creative&.effective_origin
      return reject unless creative&.has_permission?(current_user, :read)

      stream_from "agent:topic:#{@topic.id}"
    end

    def subscribe_to_agent_stream
      agent = User.find_by(id: params[:agent_id])
      return reject unless agent&.ai_user?
      return reject unless agent.created_by_id == current_user.id

      # Reconnect-grace: if a prior unsubscribed cleared routing_expression
      # (or an explicit /destroy disabled the agent and the same MCP session
      # is resubscribing without re-registering), restore it on a successful
      # claim of the per-agent stream by the owner so dispatches resume.
      if agent.claude_channel_agent? && agent.routing_expression.blank?
        agent.update_column(:routing_expression, "true")
      end

      @session_agent = agent if agent.claude_channel_agent?
      stream_from "agent:user:#{agent.id}"
    end
  end
end
