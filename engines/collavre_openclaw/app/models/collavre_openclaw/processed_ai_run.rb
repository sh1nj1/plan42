module CollavreOpenclaw
  # Durable idempotency key for OpenClaw Gateway runs. Owned by this engine so
  # the run concept stays off core collavre's general-purpose comments table.
  # comment_id is set when a comment owns the run; ON DELETE SET NULL keeps the
  # row alive as a tombstone after the comment is destroyed (review-fold).
  class ProcessedAiRun < ApplicationRecord
    self.table_name = "openclaw_processed_ai_runs"

    belongs_to :comment, class_name: "Collavre::Comment", optional: true

    validates :run_id, presence: true

    def self.processed?(run_id)
      return false if run_id.blank?

      exists?(run_id: run_id)
    end

    def self.comment_for(run_id)
      return nil if run_id.blank?

      find_by(run_id: run_id)&.comment
    end

    # Returns false when another process already claimed the run, so the caller
    # discards its duplicate.
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

    # The canonical (activity-logged) reply wins: on a lost race it reclaims the
    # run from the proactive duplicate and destroys it, leaving one comment.
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
