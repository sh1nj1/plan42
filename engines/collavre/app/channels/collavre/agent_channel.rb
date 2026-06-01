# frozen_string_literal: true

require "concurrent/map"

module Collavre
  class AgentChannel < ApplicationCable::Channel
    # Tracks the currently-active subscription token per per-session Claude
    # Channel agent so unsubscribed can tell whether THIS connection is still
    # the live subscriber. If the WS dropped after a reconnect has already
    # taken over (ActionCable's ping timeout means unsubscribed may fire
    # several seconds late, possibly AFTER the client has reconnected and
    # restored routing_expression), the late unsubscribe must NOT clear
    # routing — that would mark the actively-subscribed agent offline.
    # Per-process Concurrent::Map: the channel instance that holds the
    # subscription is in the same process as the unsubscribed callback.
    @subscription_tokens = Concurrent::Map.new
    class << self
      attr_reader :subscription_tokens
    end

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
      return unless @session_agent && @subscription_token

      # Only clear routing if this connection is still the latest subscriber
      # for this agent. If a newer connection has reconnected during the WS
      # ping-timeout window, it will have overwritten the token via subscribe_
      # to_agent_stream — clearing here would mark the live agent offline.
      current_token = self.class.subscription_tokens[@session_agent.id]
      return unless current_token == @subscription_token

      # We are the last/latest subscriber; release the slot.
      self.class.subscription_tokens.delete_pair(@session_agent.id, @subscription_token)

      @session_agent.reload
      if @session_agent.routing_expression.present?
        @session_agent.update_column(:routing_expression, nil)
      end
    rescue ActiveRecord::RecordNotFound
      # Agent deleted between subscribe and unsubscribe — nothing to clear.
      self.class.subscription_tokens.delete_pair(@session_agent.id, @subscription_token) if @session_agent && @subscription_token
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

      # Attach the stream BEFORE activating routing. Orchestration::Matcher
      # can pick this agent as soon as routing_expression becomes "true";
      # broadcasts to agent:user:<id> in the window between the UPDATE
      # committing and stream_from registering the subscription would land
      # in a stream with no subscriber, leaving the new delegated task
      # waiting on stuck recovery. Registering the subscription first means
      # by the time the agent is matchable, this connection is already
      # receiving broadcasts.
      if agent.claude_channel_agent?
        @session_agent = agent
        # Claim ownership of routing for this agent. A subsequent subscribe
        # for the same agent (reconnect) will overwrite this token, after
        # which our late unsubscribed becomes a no-op.
        @subscription_token = SecureRandom.hex(8)
        self.class.subscription_tokens[agent.id] = @subscription_token
      end
      stream_from "agent:user:#{agent.id}"

      # Reconnect-grace: if a prior unsubscribed cleared routing_expression
      # (or an explicit /destroy disabled the agent and the same MCP session
      # is resubscribing without re-registering), restore it on a successful
      # claim of the per-agent stream by the owner so dispatches resume.
      if agent.claude_channel_agent? && agent.routing_expression.blank?
        agent.update_column(:routing_expression, "true")
      end
    end
  end
end
