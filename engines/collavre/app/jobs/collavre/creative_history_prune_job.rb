# frozen_string_literal: true

module Collavre
  class CreativeHistoryPruneJob < ApplicationJob
    queue_as :default

    def perform
      deleted = 0
      prunable_change_sets.find_each do |change_set|
        change_set.destroy!
        deleted += 1
      end

      Rails.logger.info("[Collavre::CreativeHistoryPruneJob] pruned #{deleted} change sets") if deleted.positive?
      deleted
    end

    private

    def prunable_change_sets
      CreativeChangeSet
        .where(status: "applied")
        .where.not(origin: "revert")
        .where(
          "COALESCE(creative_change_sets.applied_at, creative_change_sets.created_at) < ?",
          SystemSetting.creative_history_retention_days.days.ago
        )
        .where.not(id: referenced_change_set_ids)
        .where.not(id: retained_change_set_ids)
    end

    def referenced_change_set_ids
      CreativeChangeSet.where.not(reverts_id: nil).select(:reverts_id)
    end

    def retained_change_set_ids
      ranked = CreativeChange
        .joins(:change_set)
        .where(creative_change_sets: { status: "applied" })
        .where.not(creative_change_sets: { origin: "revert" })
        .select(
          "creative_changes.creative_change_set_id, " \
          "ROW_NUMBER() OVER (" \
          "PARTITION BY creative_changes.creative_id " \
          "ORDER BY creative_change_sets.created_at DESC, creative_change_sets.id DESC" \
          ") AS history_rank"
        )

      CreativeChange
        .from(ranked, :ranked_history)
        .where("history_rank <= ?", SystemSetting.creative_history_retention_count)
        .select("ranked_history.creative_change_set_id")
    end
  end
end
