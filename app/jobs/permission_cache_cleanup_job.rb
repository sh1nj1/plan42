class PermissionCacheCleanupJob < ApplicationJob
  queue_as :default

  def perform
    # Remove cache rows for deleted creatives
    orphaned_by_creative = CreativeSharesCache
      .where.not(creative_id: Creative.select(:id))
      .delete_all

    # Remove cache rows for deleted users (exclude NULL for public shares)
    orphaned_by_user = CreativeSharesCache
      .where.not(user_id: nil)
      .where.not(user_id: User.select(:id))
      .delete_all

    # Remove cache rows for deleted shares (source_share_id no longer exists)
    orphaned_by_share = CreativeSharesCache
      .where.not(source_share_id: nil)
      .where.not(source_share_id: CreativeShare.select(:id))
      .delete_all

    Rails.logger.info(
      "[PermissionCacheCleanupJob] Cleaned up orphaned cache rows: " \
      "creative=#{orphaned_by_creative}, user=#{orphaned_by_user}, share=#{orphaned_by_share}"
    )
  end
end
