class PermissionCacheJob < ApplicationJob
  queue_as :authz

  discard_on ActiveJob::DeserializationError
  discard_on ActiveRecord::RecordNotFound

  def perform(operation, **args)
    if operation.nil?
      Rails.logger.error("[PermissionCacheJob] Received nil operation, args: #{args.inspect}")
      return
    end

    case operation.to_sym
    when :cache_owner
      cache_owner(args[:creative_id])
    when :update_owner
      update_owner(args[:creative_id], args[:old_user_id], args[:new_user_id])
    when :rebuild_for_creative
      rebuild_for_creative(args[:creative_id])
    when :propagate_share
      propagate_share(args[:creative_share_id])
    when :remove_share
      remove_share(args[:creative_share_id], args[:creative_id], args[:user_id])
    when :rebuild_user_cache_for_subtree
      rebuild_user_cache_for_subtree(args[:creative_id], args[:user_id])
    else
      Rails.logger.error("[PermissionCacheJob] Unknown operation: #{operation.inspect}, args: #{args.inspect}")
    end
  end

  private

  def cache_owner(creative_id)
    creative = Creative.find_by(id: creative_id)
    return unless creative
    Creatives::PermissionCacheBuilder.cache_owner(creative)
  end

  def update_owner(creative_id, old_user_id, new_user_id)
    creative = Creative.find_by(id: creative_id)
    return unless creative
    Creatives::PermissionCacheBuilder.update_owner(creative, old_user_id, new_user_id)
  end

  def rebuild_for_creative(creative_id)
    creative = Creative.find_by(id: creative_id)
    return unless creative
    Creatives::PermissionCacheBuilder.rebuild_for_creative(creative)
  end

  def propagate_share(creative_share_id)
    share = CreativeShare.find_by(id: creative_share_id)
    return unless share
    Creatives::PermissionCacheBuilder.propagate_share(share)
  end

  def remove_share(creative_share_id, creative_id, user_id)
    CreativeSharesCache.where(source_share_id: creative_share_id).delete_all
    creative = Creative.find_by(id: creative_id)
    return unless creative
    Creatives::PermissionCacheBuilder.rebuild_from_ancestors_for_user(creative, user_id)
  end

  def rebuild_user_cache_for_subtree(creative_id, user_id)
    creative = Creative.find_by(id: creative_id)
    return unless creative
    Creatives::PermissionCacheBuilder.rebuild_user_cache_for_subtree(creative, user_id)
  end
end
