# frozen_string_literal: true

module Collavre
  class CreativeHistoryPruneJob < ApplicationJob
    queue_as :default

    def perform
      deleted = 0
      prunable_change_sets.find_each do |change_set|
        deleted += 1 if destroy_change_set(change_set)
      end

      Rails.logger.info("[Collavre::CreativeHistoryPruneJob] pruned #{deleted} change sets") if deleted.positive?
      deleted
    end

    private

    def destroy_change_set(change_set)
      change_set.with_lock do
        next false unless still_prunable?(change_set)

        blob_ids = ActiveStorage::Attachment
          .where(record: change_set.creative_changes, name: "history_files")
          .distinct
          .pluck(:blob_id)
        change_set.destroy!
        Creatives::History.schedule_blob_purge_rechecks(blob_ids)
        true
      end
    end

    def still_prunable?(change_set)
      return false unless change_set.status == "applied" && change_set.origin != "revert"
      return false unless (change_set.applied_at || change_set.created_at) < retention_cutoff
      return false if CreativeChangeSet.exists?(reverts_id: change_set.id)

      creative_ids = change_set.creative_changes.distinct.pluck(:creative_id)
      scoped_retained_ids = retained_change_set_ids(creative_ids: creative_ids)

      !CreativeChangeSet.where(id: scoped_retained_ids).exists?(id: change_set.id)
    end

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

    def retention_cutoff
      SystemSetting.creative_history_retention_days.days.ago
    end

    def retained_change_set_ids(creative_ids: nil)
      changes = CreativeChange
        .joins(:change_set)
        .where(creative_change_sets: { status: "applied" })
        .where.not(creative_change_sets: { origin: "revert" })
      changes = changes.where(creative_id: creative_ids) if creative_ids
      ranked = changes
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
