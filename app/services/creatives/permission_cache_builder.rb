module Creatives
  class PermissionCacheBuilder
    # Creative 생성 시 소유자 캐시 추가
    def self.cache_owner(creative)
      return unless creative.user_id

      CreativeSharesCache.find_or_create_by!(
        creative_id: creative.id,
        user_id: creative.user_id
      ) do |cache|
        cache.permission = :admin
        cache.source_share_id = nil
      end
    end

    # Creative user_id 변경 시 호출
    def self.update_owner(creative, old_user_id, new_user_id)
      # 기존 소유자의 owner 캐시 삭제 (source_share_id가 nil인 것만)
      if old_user_id
        CreativeSharesCache.where(
          creative_id: creative.id,
          user_id: old_user_id,
          source_share_id: nil
        ).delete_all
      end

      # 새 소유자 캐시 추가
      cache_owner(creative) if new_user_id
    end

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
      all_descendant_ids = [ creative.id ] + creative.descendant_ids

      # "closest share wins" 의미론 적용:
      # 이 share의 자손 중 더 가까운 share가 있는 creative는 제외
      # (더 가까운 share가 해당 서브트리를 담당)
      closer_share_creative_ids = CreativeShare
        .where(user_id: user_id)
        .where(creative_id: creative.descendant_ids)  # 이 creative의 strict descendants에 있는 share들
        .where.not(permission: :no_access)
        .where.not(id: creative_share.id)  # 자기 자신 제외
        .pluck(:creative_id)

      # 더 가까운 share가 있는 creative와 그 자손들은 제외
      excluded_ids = Set.new
      if closer_share_creative_ids.any?
        excluded_ids = CreativeHierarchy
          .where(ancestor_id: closer_share_creative_ids)
          .pluck(:descendant_id)
          .to_set
      end

      ids_to_update = all_descendant_ids.reject { |id| excluded_ids.include?(id) }

      now = Time.current

      # Use individual upserts since SQLite has issues with NULL in unique indexes
      ids_to_update.each do |cid|
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
      descendants = creative.self_and_descendants

      # 해당 creative와 자손들의 캐시 삭제 (share 기반만 - owner entries 유지)
      CreativeSharesCache.where(creative_id: descendants.pluck(:id))
                         .where.not(source_share_id: nil)
                         .delete_all

      # 새 부모 기준으로 조상 share 전파
      rebuild_from_ancestors_for_subtree(creative)

      # 소유자 캐시 재확인 (혹시 누락된 경우)
      descendants.each do |c|
        cache_owner(c) if c.user_id
      end
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
