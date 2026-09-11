# frozen_string_literal: true

module Collavre
  class Task
    # A newer active turn temporarily owns completion of an abandoned replay.
    # If it ends without a result, ask the abandoned turn again after commit.
    module ReplayLoopCompletion
      extend ActiveSupport::Concern

      included do
        after_update_commit :recheck_abandoned_replays, if: :saved_change_to_status?
      end

      private

      # Admission persists this link on both running turns and queued waiters.
      # Settle before looking for abandoned predecessors to avoid a duplicate
      # completion check; abandon_replay! handles repeated terminal callbacks.
      def settle_inline_replay(completed: false)
        original_ids = CliProxy::ReplayClaims.ids(trigger_event_payload)
        return false if original_ids.empty?

        # Promotion may fold a newer replay into an older waiter, so the login
        # task need not predate the survivor. Scope and non-self checks still apply.
        originals = Task.where(agent_id: agent_id, creative_id: creative_id, topic_id: topic_id, status: "done")
                        .where.not(id: id).where(id: original_ids).to_a
        originals.each do |original|
          completed ? CliProxy::ReplayClaims.complete!(original) : CliProxy::InlineLogin.abandon_replay!(original)
        end
        originals.any?
      end

      def loop_completion_delegated_to_replay?
        login = trigger_event_payload&.fetch("engine_login", {})
        login && (login["retryable"] || login["replay_completed"])
      end

      def completed_inline_replay?
        done? && !trigger_event_payload&.key?("engine_login") && !ended_undelivered?
      end

      def recheck_abandoned_replays
        return settle_inline_replay(completed: true) if completed_inline_replay?
        return unless status.in?(%w[failed cancelled escalated]) && trigger_event_name == "comment_created"
        return if settle_inline_replay
        return unless creative&.parent&.drop_trigger_enabled?
        return unless creative.data&.dig("trigger", "loop", "state") == "running"

        Task.where(creative_id: creative_id, topic_id: topic_id, trigger_event_name: "comment_created", status: "done")
            .where("created_at < :time OR (created_at = :time AND id < :id)", time: created_at, id: id)
            .find_each(order: :desc) do |previous|
          next unless previous.trigger_event_payload&.dig("engine_login", "replay_abandoned")

          previous.fire_completion_callbacks_after_external_claim
          break
        end
      end
    end
  end
end
