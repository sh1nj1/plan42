module CollavreOpenclaw
  # Cross-process / durable idempotency for OpenClaw Gateway runs.
  #
  # The Gateway re-delivers a run's "final" event to every process sharing the
  # Gateway; only the issuing process treats it as solicited, every other process
  # sees it as "proactive". Keying on the Gateway runId collapses those into the
  # single comment already created, regardless of process, reconnect, or content
  # drift. Owned by this engine so the run concept stays out of core collavre and
  # off the general-purpose comments table.
  #
  # comment_id references the canonical (activity-logged) comment when one
  # survives; the migration's ON DELETE SET NULL keeps the run row alive as a
  # tombstone after the comment is destroyed (review-fold), so the run is still
  # recognized as already-handled.
  class ProcessedAiRun < ApplicationRecord
    self.table_name = "openclaw_processed_ai_runs"

    belongs_to :comment, class_name: "Collavre::Comment", optional: true

    validates :run_id, presence: true

    def self.processed?(run_id)
      return false if run_id.blank?

      exists?(run_id: run_id)
    end

    # The comment that currently owns a run, if it still exists.
    def self.comment_for(run_id)
      return nil if run_id.blank?

      find_by(run_id: run_id)&.comment
    end

    # Record a run produced by a non-canonical (proactive) comment. Returns true
    # when this comment owns the run, false when it lost the race (another
    # process already claimed it) — the caller should then discard its duplicate.
    def self.claim_proactive(run_id, comment)
      return true if run_id.blank?

      create!(run_id: run_id, comment: comment)
      true
    rescue ActiveRecord::RecordNotUnique
      false
    rescue StandardError => e
      Rails.logger.warn("[CollavreOpenclaw::ProcessedAiRun] Failed to claim run #{run_id}: #{e.message}")
      false
    end

    # Record a run produced by the canonical (solicited, activity-logged) reply.
    # On a lost race — a proactive duplicate already claimed the run — the
    # canonical comment reclaims it: the run row is repointed here and the
    # proactive duplicate comment is destroyed so exactly one comment survives.
    def self.claim_canonical(run_id, comment)
      return if run_id.blank? || comment.nil?

      create!(run_id: run_id, comment: comment)
    rescue ActiveRecord::RecordNotUnique
      reclaim_for(run_id, comment)
    rescue StandardError => e
      Rails.logger.warn("[CollavreOpenclaw::ProcessedAiRun] Failed to claim run #{run_id}: #{e.message}")
    end

    def self.reclaim_for(run_id, canonical)
      row = find_by(run_id: run_id)
      return if row.nil?

      duplicate = row.comment
      if duplicate.nil? || duplicate.id == canonical.id
        row.update_column(:comment_id, canonical.id)
        return
      end

      row.update_column(:comment_id, canonical.id)
      duplicate.destroy
      Rails.logger.warn(
        "[CollavreOpenclaw::ProcessedAiRun] Reclaimed run #{run_id} for comment #{canonical.id}; " \
        "removed proactive duplicate #{duplicate.id}"
      )
    rescue StandardError => e
      Rails.logger.warn("[CollavreOpenclaw::ProcessedAiRun] Failed to reclaim run #{run_id}: #{e.message}")
    end
    private_class_method :reclaim_for
  end
end
