class PermissionCacheCleanupJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 1000

  def perform
    orphaned_by_creative = delete_in_batches(
      CreativeSharesCache.where.not(creative_id: Creative.select(:id))
    )

    orphaned_by_user = delete_in_batches(
      CreativeSharesCache.where.not(user_id: nil).where.not(user_id: User.select(:id))
    )

    orphaned_by_share = delete_in_batches(
      CreativeSharesCache.where.not(source_share_id: nil).where.not(source_share_id: CreativeShare.select(:id))
    )

    Rails.logger.info(
      "[PermissionCacheCleanupJob] Cleaned up orphaned cache rows: " \
      "creative=#{orphaned_by_creative}, user=#{orphaned_by_user}, share=#{orphaned_by_share}"
    )
  end

  private

  def delete_in_batches(scope)
    total_deleted = 0
    loop do
      deleted = scope.limit(BATCH_SIZE).delete_all
      total_deleted += deleted
      break if deleted < BATCH_SIZE
    end
    total_deleted
  end
end
