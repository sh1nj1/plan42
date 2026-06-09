# frozen_string_literal: true

module Collavre
  # Typing-indicator / "responding" presence for Claude Channel (MCP) agents.
  #
  # RubyLLM agents broadcast agent_status ("thinking" → "streaming" heartbeats →
  # "idle") from inside their long-running AiAgentJob, which is what drives the
  # chat typing indicator and Stop button. The Claude Channel path has no such
  # loop: AiAgentService#delegate_to_claude_channel broadcasts the dispatch and
  # returns immediately, with the reply arriving asynchronously via /reply. So
  # the chat showed nothing while Claude worked.
  #
  # This job restores parity. Enqueued once per Claude dispatch, it:
  #   - while the task is "delegated" and a session is LIVE → broadcasts a
  #     working agent_status and re-enqueues itself every HEARTBEAT_SECONDS
  #     (under the frontend's 10s AGENT_STATUS_TIMEOUT) so the indicator stays up;
  #   - when no live session remains (never connected, or dropped mid-turn) →
  #     broadcasts "idle" to clear the indicator and posts an authorless system
  #     notice so a human sees the channel is disconnected rather than a phantom
  #     "thinking"; (CancelOfflineDelegatedTasksJob owns the task-state cleanup);
  #   - once the task leaves "delegated" (a /reply completed it, or it was
  #     cancelled) → stops without re-enqueuing. The reply path broadcasts the
  #     final "idle" itself, so the indicator clears immediately on reply.
  class ClaudeChannelPresenceJob < ApplicationJob
    queue_as :default

    # Re-broadcast cadence. Must stay below the frontend AGENT_STATUS_TIMEOUT
    # (10s) so the indicator never flickers off between beats, with room for one
    # missed beat (queue jitter, GC pause).
    HEARTBEAT_SECONDS = 5

    def perform(task_id)
      task = Task.find_by(id: task_id)
      return unless task

      agent = task.agent
      return unless agent&.claude_channel_agent?

      # A /reply completed the task (or it was cancelled). The reply path already
      # broadcast the final "idle"; nothing more to do, and crucially do NOT post
      # a disconnect notice for a normally-finished turn.
      return unless task.reload.status == "delegated"

      creative = resolve_creative(task)
      return unless creative

      AgentSubscription.reap_stale!(agent.id)

      # Reuse the canonical status broadcaster that drives the typing indicator
      # for every other agent (AiAgentService#execute_llm_conversation), so the
      # "thinking"/"idle" payload stays identical across both paths.
      lifecycle = AiAgent::AgentLifecycleManager.new(task: task, agent: agent, creative: creative)

      if AgentSubscription.live.where(agent_id: agent.id).exists?
        lifecycle.broadcast_status("thinking")
        self.class.set(wait: HEARTBEAT_SECONDS.seconds).perform_later(task_id)
      else
        lifecycle.broadcast_status("idle")
        post_disconnect_notice(creative, task)
      end
    end

    private

    def resolve_creative(task)
      creative_id = task.creative_id || task.trigger_event_payload&.dig("creative", "id")
      Creative.find_by(id: creative_id)&.effective_origin
    end

    def resolve_topic_id(task)
      task.topic_id || task.trigger_event_payload&.dig("topic", "id")
    end

    # Authorless, non-dispatching system message so the human sees the channel is
    # offline. skip_dispatch is essential: an authorless comment that matched the
    # agent's routing would otherwise spawn a fresh delegated task — an infinite
    # disconnect-notice loop.
    def post_disconnect_notice(creative, task)
      topic_id = resolve_topic_id(task)
      return unless topic_id

      creative.comments.create!(
        content: I18n.t(
          "collavre.claude_channel.disconnected",
          default: "🔌 Claude Channel과 연결되어 있지 않습니다 — 다시 연결되면 메시지가 전달됩니다."
        ),
        topic_id: topic_id,
        private: false,
        skip_default_user: true,
        skip_dispatch: true
      )
    end
  end
end
