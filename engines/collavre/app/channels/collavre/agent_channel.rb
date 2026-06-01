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
    #
    # Cross-process ownership: the subscription token is persisted on the
    # users row (routing_subscription_token). A late unsubscribe whose token
    # has been overwritten by a newer subscribe — possibly on a DIFFERENT
    # Puma/Kamal process — matches zero rows under the conditional UPDATE
    # below and becomes a no-op. This is required for scaled deployments
    # (WEB_CONCURRENCY > 1, Solid Cable) where the old connection's
    # unsubscribed and the reconnect's subscribe may not share a process.
    def unsubscribed
      return unless @session_agent && @subscription_token

      rows_updated = User.where(
        id: @session_agent.id,
        routing_subscription_token: @subscription_token
      ).update_all(
        routing_expression: nil,
        routing_subscription_token: nil,
        updated_at: Time.current
      )

      if rows_updated.zero?
        # A newer subscribe (any process) has overwritten the token. The
        # live owner is still subscribed — do not clobber its routing and
        # do not schedule cancellation; the live owner's lifecycle owns it.
        return
      end

      # Reconnect-grace cancellation: AgentChannel#unsubscribed only makes the
      # agent unroutable. Any task already in "delegated" still holds its
      # ResourceTracker slot — the dispatch was broadcast to a now-dead stream
      # so no client remains to call /reply, and the slot would stay held
      # until StuckDetectorJob times out. The job below cancels those tasks
      # after a grace window, but only if the agent is still offline (the
      # job rechecks routing_expression and routing_subscription_token).
      CancelOfflineDelegatedTasksJob
        .set(wait: CancelOfflineDelegatedTasksJob::GRACE_SECONDS.seconds)
        .perform_later(@session_agent.id, @subscription_token)
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[AgentChannel] unsubscribed conditional clear failed: #{e.message}")
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
        # Claim cross-process ownership of routing for this agent. A
        # subsequent subscribe (any process) will overwrite this token on
        # the users row, after which our late unsubscribed's conditional
        # UPDATE matches zero rows and becomes a no-op.
        @subscription_token = SecureRandom.hex(8)
        agent.update_column(:routing_subscription_token, @subscription_token)
      end
      stream_from "agent:user:#{agent.id}"

      # Reconnect-grace: if a prior unsubscribed cleared routing_expression
      # (or an explicit /destroy disabled the agent and the same MCP session
      # is resubscribing without re-registering), restore it on a successful
      # claim of the per-agent stream by the owner so dispatches resume.
      if agent.claude_channel_agent? && agent.reload.routing_expression.blank?
        agent.update_column(:routing_expression, "true")
      end
    end
  end
end
