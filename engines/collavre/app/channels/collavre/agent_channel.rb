# frozen_string_literal: true

module Collavre
  class AgentChannel < ApplicationCable::Channel
    # Heartbeat for Claude Channel presence rows. Fires for every subscription,
    # but touch_presence is a no-op unless this connection registered a presence
    # row (agent_id subscribe by a Claude Channel agent), so topic/legacy/non-
    # Claude subscribers pay only an idle timer.
    periodically :touch_presence, every: AgentSubscription::HEARTBEAT_SECONDS

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
    # can call DELETE /api/v1/agent/:id, a Claude Channel session would
    # otherwise stay matchable (routing_expression: "true") and any future
    # comment on a creative still shared with the agent would dispatch into an
    # empty stream — delegated work that only clears via stuck recovery.
    #
    # One shared agent can have MANY concurrent sessions, so routing is gated
    # on PRESENCE: this session drops its own AgentSubscription row, and
    # routing is cleared only when NO rows remain. A still-live sibling session
    # keeps its row, so routing stays active and its in-flight work is never
    # cancelled. Done under the agent's row lock so a concurrent subscribe on
    # the same agent serializes (no clear-vs-activate race).
    #
    # Cross-process / late unsubscribe: the row was keyed by this connection's
    # own @subscription_token. A stale unsubscribe whose row was already
    # removed (newer subscribe took over, or a different Puma/Kamal process)
    # deletes zero rows and becomes a no-op — required for scaled deployments
    # (WEB_CONCURRENCY > 1, Solid Cable).
    def unsubscribed
      return unless @session_agent && @subscription_token

      cleared = false
      @session_agent.with_lock do
        deleted = AgentSubscription
                  .where(agent_id: @session_agent.id, token: @subscription_token)
                  .delete_all
        # Stale: our presence row is already gone. The live owner's lifecycle
        # owns routing — do not clobber it, do not schedule cancellation.
        next if deleted.zero?

        # Drop crash-orphaned sibling rows (a Puma/ActionCable process that
        # died without firing unsubscribed) before reading presence, so a dead
        # row cannot masquerade as a live sibling and pin routing on forever.
        AgentSubscription.reap_stale!(@session_agent.id)

        # Another session is still LIVE on this shared agent. Keep routing
        # active; whichever session unsubscribes last clears it.
        next if AgentSubscription.live.where(agent_id: @session_agent.id).exists?

        @session_agent.update_columns(
          routing_expression: nil,
          routing_subscription_token: nil
        )
        cleared = true
      end

      return unless cleared

      # Reconnect-grace cancellation: clearing routing only makes the agent
      # unroutable. Any task already "delegated" still holds its ResourceTracker
      # slot — the dispatch was broadcast to a now-dead stream so no client
      # remains to call /reply, and the slot would stay held until
      # StuckDetectorJob times out. The job cancels those tasks after a grace
      # window, but only if the agent is still offline (it rechecks
      # routing_expression AND that no session has resubscribed).
      CancelOfflineDelegatedTasksJob
        .set(wait: CancelOfflineDelegatedTasksJob::GRACE_SECONDS.seconds)
        .perform_later(@session_agent.id, @subscription_token)
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("[AgentChannel] unsubscribed presence clear failed: #{e.message}")
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
      @session_agent = agent if agent.claude_channel_agent?
      @subscription_token = SecureRandom.hex(8) if agent.claude_channel_agent?
      stream_from "agent:user:#{agent.id}"

      # Record this session's presence row and (re)activate routing under the
      # agent's row lock, so a concurrent unsubscribe on the same shared agent
      # serializes against this and cannot clear routing out from under a live
      # session. routing_subscription_token is kept as the most-recent-session
      # marker (debugging / grace-job arg); presence rows are the real gate.
      if agent.claude_channel_agent?
        agent.with_lock do
          # Self-heal: clear crash-orphaned rows for this agent before counting
          # so this session's activation isn't blocked from, and presence reads
          # aren't fooled by, a dead process's leftover row.
          AgentSubscription.reap_stale!(agent.id)
          AgentSubscription.create!(agent_id: agent.id, token: @subscription_token)
          agent.update_columns(
            routing_subscription_token: @subscription_token,
            routing_expression: "true"
          )
        end
      end
    end

    # Periodic heartbeat callback: keep this session's presence row live. No-op
    # once the row is gone (rotated by a newer subscribe, or reaped), so it can
    # never resurrect a removed row.
    def touch_presence
      return unless @session_agent && @subscription_token

      AgentSubscription.touch!(@session_agent.id, @subscription_token)
    end
  end
end
