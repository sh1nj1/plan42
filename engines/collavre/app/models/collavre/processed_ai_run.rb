module Collavre
  # Durable tombstone for OpenClaw Gateway runs that have already produced a
  # visible comment. Survives comment destruction (e.g. the review workflow
  # folding a reply into its quoted comment), so a run whose comment-level marker
  # is lost is still recognized as already-handled and not duplicated.
  #
  # See CreateProcessedAiRuns migration for why the comments.openclaw_run_id
  # column alone is insufficient (one slot per comment vs. N runs per comment).
  class ProcessedAiRun < ApplicationRecord
    self.table_name = "processed_ai_runs"

    validates :run_id, presence: true

    # Idempotently record a run as handled. Safe to call from multiple processes:
    # the unique index makes a concurrent double-insert a no-op rather than an
    # error. Returns true when the run is recorded (now or already), false on a
    # blank run_id.
    def self.record(run_id)
      return false if run_id.blank?

      create!(run_id: run_id)
      true
    rescue ActiveRecord::RecordNotUnique
      true
    rescue StandardError => e
      Rails.logger.warn("[Collavre::ProcessedAiRun] Failed to record run #{run_id}: #{e.message}")
      false
    end

    def self.processed?(run_id)
      return false if run_id.blank?

      exists?(run_id: run_id)
    end
  end
end
