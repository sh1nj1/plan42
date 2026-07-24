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

      class_methods do
        # Re-broadcast the recorded decision for each given request_id that belongs
        # to this agent and has been decided. Called when a Claude Channel session
        # sends the request_ids it still holds pending after a (re)subscribe
        # (pull-on-resubscribe): broadcast_claude_channel_permission_decision fires
        # once into the transient agent:user:<id> stream, so a decision clicked
        # while the plugin's WebSocket was reconnecting lands in a subscriber-less
        # stream and is lost — leaving the suspended tool hung with no retry path.
        #
        # The plugin's pending set is the SOLE bound: there is no wall-clock window,
        # so a decision made during an outage of any length is still redelivered,
        # and a decision the plugin already consumed is simply never requested. The
        # coarse action LIKE filter (one per requested id) is narrowed by an exact
        # request_id match per row before re-broadcasting; replay is idempotent
        # (PermissionCoordinator.claim ignores a request_id it no longer holds), so
        # an over-broad LIKE match is a harmless no-op on the plugin side.
        def replay_claude_channel_permission_decisions_for(agent_id, request_ids)
          ids = Array(request_ids).filter_map { |r| r.to_s.presence }.uniq
          return if ids.empty?

          # Build the coarse "action LIKE '%<rid>%'" prefilter with Arel matchers
          # rather than a raw SQL fragment so the wildcards stay bound parameters
          # (the surrounding %…% is ours; sanitize_sql_like escapes any %/_ inside
          # the id). No interpolation into SQL — Brakeman-clean and identical
          # semantics to the old OR-joined LIKE.
          matcher = ids
            .map { |rid| arel_table[:action].matches("%#{sanitize_sql_like(rid)}%") }
            .reduce(:or)
          where(user_id: agent_id)
            .where.not(action_executed_at: nil)
            .where(matcher)
            .find_each do |comment|
              next unless comment.claude_channel_permission?
              next unless ids.include?(comment.claude_channel_permission_request_id)

              comment.rebroadcast_claude_channel_permission_decision
            end
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
