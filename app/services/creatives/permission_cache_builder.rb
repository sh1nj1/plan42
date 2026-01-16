module Creatives
  class PermissionCacheBuilder
    # CreativeShare 생성/업데이트 시 호출
    def self.propagate_share(creative_share)
      return if creative_share.destroyed?

      creative = creative_share.creative
      user_id = creative_share.user_id
      permission = creative_share.permission

      # no_access는 캐시에 저장하지 않음 - 대신 기존 캐시 삭제
      if creative_share.no_access?
        descendant_ids = [ creative.id ] + creative.descendant_ids
        CreativeSharesCache.where(creative_id: descendant_ids, user_id: user_id).delete_all
        return
      end

      # 해당 creative + 모든 자손 ID (closure_tree 사용)
      descendant_ids = [ creative.id ] + creative.descendant_ids

      now = Time.current

      # Use individual upserts since SQLite has issues with NULL in unique indexes
      descendant_ids.each do |cid|
        cache_entry = CreativeSharesCache.find_or_initialize_by(
          creative_id: cid,
          user_id: user_id
        )
        cache_entry.assign_attributes(
          permission: CreativeShare.permissions[permission],
          source_share_id: creative_share.id,
          updated_at: now
        )
        cache_entry.save!
      end
    end

    # CreativeShare 삭제 시 호출
    def self.remove_share(creative_share)
      CreativeSharesCache.where(source_share_id: creative_share.id).delete_all

      # 삭제 후 조상에서 다른 share가 있으면 다시 전파
      rebuild_from_ancestors(creative_share.creative, creative_share.user_id)
    end

    # Creative parent_id 변경 시 호출
    def self.rebuild_for_creative(creative)
      descendant_ids = [ creative.id ] + creative.descendant_ids

      # 해당 creative와 자손들의 캐시 삭제
      CreativeSharesCache.where(creative_id: descendant_ids).delete_all

      # 새 부모 기준으로 조상 share 전파
      rebuild_from_ancestors_for_subtree(creative)
    end

    class << self
      private

      def rebuild_from_ancestors(creative, user_id)
        # 조상들 중 해당 user에 대한 share 찾기
        ancestor_ids = creative.ancestor_ids
        return if ancestor_ids.empty?

        ancestor_share = CreativeShare
          .where(creative_id: ancestor_ids, user_id: user_id)
          .where.not(permission: :no_access)
          .joins("INNER JOIN creative_hierarchies ch ON creative_shares.creative_id = ch.ancestor_id")
          .where("ch.descendant_id = ?", creative.id)
          .order("ch.generations ASC")
          .first

        propagate_share(ancestor_share) if ancestor_share
      end

      def rebuild_from_ancestors_for_subtree(creative)
        ancestor_ids = creative.ancestor_ids
        return if ancestor_ids.empty?

        # 조상들의 모든 share 가져오기 (no_access 제외)
        ancestor_shares = CreativeShare
          .where(creative_id: ancestor_ids)
          .where.not(permission: :no_access)

        ancestor_shares.each do |share|
          propagate_share(share)
        end
      end
    end
  end
end
