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

      # Raised when a decision was already recorded, so a double-click (or a
      # concurrent approve+deny) resolves to exactly one decision.
      class AlreadyDecided < StandardError; end

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
