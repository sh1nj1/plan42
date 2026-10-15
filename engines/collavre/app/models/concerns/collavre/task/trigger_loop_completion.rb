# frozen_string_literal: true

module Collavre
  class Task
    module TriggerLoopCompletion
      extend ActiveSupport::Concern

      included do
        # A settling worker may record delivery after Stop committed its status.
        after_update_commit :release_terminated_keep_turn, if: -> { saved_change_to_status? || saved_change_to_trigger_event_payload? }
      end

      private

      # A terminal turn without usable output cannot produce a completion callback.
      def release_terminated_keep_turn
        return unless recheck_abandonment_candidate?
        return unless creative

        target = creative
        target.with_lock do
          config = target.data&.dig("trigger", "loop")
          next unless target.keep_loop? && config["state"] == "running"
          next unless config["trigger_topic_id"] == topic_id && terminated_keep_turn?(target)
          next if surviving_keep_turn?(target)
          # Restored dispatches have no sibling Task until their queued job starts.
          next if Orchestration::DeliveryRecord.pending_restoration?(self.class.find(id), comment_id: config["current_comment_id"])

          config["state"] = "awaiting_user"
          config["control_version"] = config.fetch("control_version", 0) + 1
          target.update!(data: target.data)
        end
      end

      def terminated_keep_turn?(target)
        task = self.class.find(id)
        task.send(:recheck_abandonment_candidate?) && target.trigger_loop_task?(task)
      end

      # Coalescing and ambient fan-out may leave another task owning this turn.
      def surviving_keep_turn?(target)
        self.class.where(creative_id: creative_id, topic_id: topic_id, trigger_event_name: "comment_created")
            .where(status: ACTIVE_STATUSES + Orchestration::DeliveryRecord::RESTORABLE_STATUSES).where.not(id: id).any? do |task|
          task.creative = target
          target.trigger_loop_task?(task) && (task.active? || task.send(:trigger_loop_completion_eligible?) ||
            Orchestration::DeliveryRecord.pending_restoration?(task, comment_id: target.data.dig("trigger", "loop", "current_comment_id")))
        end
      end

      def trigger_loop_candidate?
        return false unless saved_change_to_attribute?("status")

        trigger_loop_completion_eligible?
      end

      # State-only eligibility check (no save-lifecycle dependency).
      # Reused by trigger_loop_candidate? for the callback path and by
      # fire_completion_callbacks_after_external_claim for explicit replay.
      def trigger_loop_completion_eligible?
        return false unless status == "done"
        # Pending and completed replays own completion instead of the login card.
        return false if loop_completion_delegated_to_replay? || unsuccessful_loop_response?
        return false unless trigger_event_name == "comment_created"
        return false unless creative&.trigger_loop_enabled? && creative.trigger_loop_task?(self)

        # Only trigger loop check for tasks in the loop's trigger topic
        # to avoid cross-topic contamination from unrelated AI conversations
        loop_config = creative.data&.dig("trigger", "loop")
        return false unless loop_config && loop_config["state"] == "running"

        trigger_topic_id = loop_config["trigger_topic_id"]
        trigger_topic_id.nil? || trigger_topic_id == topic_id
      end

      def check_trigger_loop_completion
        snapshot = creative.data&.dig("trigger", "loop")&.deep_dup
        cooldown = (snapshot&.dig("cooldown_seconds") || 10).to_i
        queue = cooldown.positive? ? TriggerLoopCheckJob.set(wait: cooldown.seconds) : TriggerLoopCheckJob
        job = queue.perform_later(id)
        raise ActiveJob::EnqueueError if snapshot&.dig("source") == "keep" && !job
      rescue StandardError => error
        raise unless snapshot&.dig("source") == "keep"

        recover_loop_check_enqueue(snapshot)
        Rails.logger.error("[Task] Loop check enqueue failed for task #{id}: #{error.class}: #{error.message}")
      end

      # The task is already committed; release only the exact turn we tried to queue.
      def recover_loop_check_enqueue(snapshot)
        creative.with_lock do
          config = creative.data&.dig("trigger", "loop")
          next unless config == snapshot && config["state"] == "running"

          config["state"] = "awaiting_user"
          config["control_version"] = config.fetch("control_version", 0) + 1
          creative.update!(data: creative.data)
        end
      end
    end
  end
end
