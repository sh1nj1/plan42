# frozen_string_literal: true

module Collavre
  # Callbacks release promptly; this sweep also covers jobs that never reached
  # admission and callbacks lost to a process exit. It never spends an iteration.
  class KeepLoopReconcileJob < ApplicationJob
    queue_as :default
    RECOVERY_KEY = "keep_loop_recovery"

    def perform
      Creative.where("data -> 'trigger' -> 'loop' ->> 'source' = ?", "keep")
        .find_each { |creative| reconcile(creative) }
    end

    private

    def grace
      seconds = SystemSetting.cached_value("keep_loop_reconcile_grace_seconds", 900).to_i
      seconds.positive? ? seconds.seconds : 15.minutes
    end

    def reconcile(creative)
      snapshot = creative.data.dig("trigger", "loop").deep_dup
      return unless %w[running pending_verification].include?(snapshot["state"])

      Comments::TopicMutation.call(snapshot["trigger_topic_id"], creative.id) do
        creative.with_lock do
          next unless creative.data.dig("trigger", "loop") == snapshot

          reconcile_locked(creative, snapshot)
        end
      end
    rescue StandardError, NotImplementedError => error
      Rails.logger.error("[KeepLoopReconcileJob] creative=#{creative.id}: #{error.class}: #{error.message}")
    end

    def reconcile_locked(creative, snapshot)
      ownership = Orchestration::KeepLoopOwnership.new(creative, grace: grace)
      activity_at = ownership.activity_at
      trigger = creative.data["trigger"]
      if ownership.live?
        trigger.delete(RECOVERY_KEY)
      else
        marker = trigger[RECOVERY_KEY]
        marker = { "snapshot" => snapshot, "since" => activity_at.iso8601(6) } unless marker&.dig("snapshot") == snapshot
        trigger[RECOVERY_KEY] = marker
        if Time.iso8601(marker.fetch("since")) <= grace.ago
          snapshot["state"] = "awaiting_user"
          snapshot["control_version"] = snapshot.fetch("control_version", 0) + 1
          trigger["loop"] = snapshot
          trigger.delete(RECOVERY_KEY)
        end
      end
      creative.save! if creative.changed?
    end
  end
end
