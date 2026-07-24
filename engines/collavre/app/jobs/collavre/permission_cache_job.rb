module Collavre
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
      propagate_share(args[:creative_share_id], purge_stale: args.fetch(:purge_stale, false))
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

  def propagate_share(creative_share_id, purge_stale: false)
    # A relocated/reassigned share leaves stale cache rows keyed to it at the old
    # location. When asked, delete them here — in this same job, immediately
    # before re-propagating — never as a separate job. Both the purge and the
    # propagate key on source_share_id, and the authz queue runs two threads, so
    # a standalone purge could execute AFTER propagate and delete the rows it
    # just wrote, leaving the share with no cache until an unrelated rebuild.
    # Folding the purge in guarantees purge-before-propagate ordering while
    # keeping the work off the commit path (the async, prolonged-grant window the
    # CTO accepted is preserved). Purge runs before the find_by so it still fires
    # even if the share was destroyed after enqueue.
    purge_share_cache(creative_share_id) if purge_stale
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

  # Purge the stale cache rows a relocated/reassigned share left behind. Only
  # ever called from propagate_share (never enqueued standalone) so the delete
  # cannot race the re-propagation on a separate authz-queue thread.
  def purge_share_cache(creative_share_id)
    CreativeSharesCache.where(source_share_id: creative_share_id).delete_all
  end

  def rebuild_user_cache_for_subtree(creative_id, user_id)
    creative = Creative.find_by(id: creative_id)
    return unless creative
    Creatives::PermissionCacheBuilder.rebuild_user_cache_for_subtree(creative, user_id)
  end
end
end
