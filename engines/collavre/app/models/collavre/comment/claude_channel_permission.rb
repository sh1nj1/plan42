# frozen_string_literal: true

module Collavre
  class Comment < ApplicationRecord
    # A native Claude Code tool-permission prompt surfaced into a topic as a
    # structured approval comment (built by Api::V1::AgentsController#notify when
    # the relayed notify carries a permission_request_id). It reuses the native
    # approval comment UI — approver gate, approve button, ✅/🚫 decided label —
    # but a decision does NOT execute a tool server-side (the tool runs inside
    # the remote Claude Code process). Instead approve/deny relays the decision
    # over the agent stream so the MCP plugin resolves the paused tool call.
    module ClaudeChannelPermission
      extend ActiveSupport::Concern

      ACTION_TYPE = "claude_channel_permission"

      # How far back a (re)subscribing session replays decided permission prompts.
      # broadcast_claude_channel_permission_decision fires once into the transient
      # agent:user:<id> stream; a decision clicked while the plugin's WebSocket was
      # reconnecting lands in a subscriber-less stream and is lost, leaving the
      # suspended tool hung with no retry path. On resubscribe we re-broadcast
      # decisions made within this window so the redelivered decision resolves the
      # paused call. The window only needs to cover the reconnect gap: a decision
      # clicked while the plugin is connected is delivered live and never needs
      # replay. Replay is idempotent (PermissionCoordinator.claim ignores a
      # request_id it no longer holds pending), so the bound is purely a cost knob.
      PERMISSION_DECISION_REPLAY_WINDOW = 5.minutes

      # Raised when a decision was already recorded, so a double-click (or a
      # concurrent approve+deny) resolves to exactly one decision.
      class AlreadyDecided < StandardError; end

      class_methods do
        # Re-broadcast every permission decision made for this agent within the
        # replay window. Called when a Claude Channel session (re)subscribes so a
        # decision lost during a WebSocket reconnect gap is redelivered. Scoped by
        # the agent's user_id (the broadcast target) and bounded by
        # PERMISSION_DECISION_REPLAY_WINDOW; the coarse action LIKE filter is
        # narrowed by claude_channel_permission? per row before re-broadcasting.
        def replay_undelivered_claude_channel_permission_decisions(agent_id, since:)
          where(user_id: agent_id)
            .where.not(action_executed_at: nil)
            .where(action_executed_at: since..)
            .where("action LIKE ?", "%#{ACTION_TYPE}%")
            .find_each(&:rebroadcast_claude_channel_permission_decision)
        end
      end

      # True when this comment's action payload is a Claude Channel permission
      # prompt (vs. a native execute_tool/approve_tool action).
      def claude_channel_permission?
        claude_channel_permission_action.present?
      end

      def claude_channel_permission_request_id
        claude_channel_permission_action&.dig("request_id")
      end

      # The decision, once made, is persisted into the action payload so the
      # rendered comment can distinguish ✅ approved from 🚫 denied.
      def claude_channel_permission_denied?
        claude_channel_permission_action&.dig("decision") == "deny"
      end

      # Atomically record the human's allow/deny: stamp action_executed_at/by
      # (which hides the buttons and marks the comment decided) and persist the
      # decision into the action payload. Raises AlreadyDecided if a decision was
      # already recorded.
      def decide_claude_channel_permission!(behavior, by:)
        behavior = behavior.to_s
        raise ArgumentError, "behavior must be allow or deny" unless %w[allow deny].include?(behavior)

        with_lock do
          reload
          raise AlreadyDecided if action_executed_at.present?

          payload = claude_channel_permission_action
          raise ArgumentError, "not a Claude Channel permission comment" unless payload

          payload["decision"] = behavior
          update!(
            action: JSON.pretty_generate(payload),
            action_executed_at: Time.current,
            action_executed_by: by
          )
        end
      end

      # Relay the decision to the suspended session over the agent stream. The
      # MCP plugin matches request_id against the prompts it surfaced, so sibling
      # sessions sharing this (shared) agent ignore a request_id they never
      # raised. task_id is intentionally absent: the decision only unblocks the
      # paused tool call; the in-flight delegated task completes later via /reply.
      def broadcast_claude_channel_permission_decision(behavior)
        request_id = claude_channel_permission_request_id
        return false if request_id.blank? || user_id.blank?

        AgentChannel.broadcast_to_agent(user_id, {
          type: "permission_decision",
          request_id: request_id,
          behavior: behavior.to_s,
          agent_id: user_id
        })
        true
      end

      # Replay this comment's already-recorded decision (used by the resubscribe
      # path). Unlike broadcast_claude_channel_permission_decision the behavior is
      # read from the persisted payload rather than passed in, and only a comment
      # that is both a permission prompt and decided re-broadcasts — a still-
      # pending prompt has no decision to deliver.
      def rebroadcast_claude_channel_permission_decision
        return false unless claude_channel_permission?

        decision = claude_channel_permission_action&.dig("decision")
        return false if decision.blank?

        broadcast_claude_channel_permission_decision(decision)
      end

      private

      def claude_channel_permission_action
        return nil if action.blank?

        parsed = JSON.parse(action)
        parsed.is_a?(Hash) && parsed["action"] == ACTION_TYPE ? parsed : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
