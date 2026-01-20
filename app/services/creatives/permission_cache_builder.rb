module Creatives
  class PermissionCacheBuilder
    # Creative 생성 시 소유자 캐시 추가
    def self.cache_owner(creative)
      return unless creative.user_id

      CreativeSharesCache.upsert(
        {
          creative_id: creative.id,
          user_id: creative.user_id,
          permission: CreativeShare.permissions[:admin],
          source_share_id: nil
        },
        unique_by: [ :creative_id, :user_id ],
        update_only: [ :permission ]
      )
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

      # 해당 creative + 모든 자손 ID (closure_tree 사용)
      all_descendant_ids = [ creative.id ] + creative.descendant_ids

      # "closest share wins" 의미론 적용:
      # 이 share의 자손 중 더 가까운 share가 있는 creative는 제외
      # (더 가까운 share가 해당 서브트리를 담당)
      # no_access도 closer share로 인정 (public share보다 우선)
      closer_share_creative_ids = CreativeShare
        .where(user_id: user_id)
        .where(creative_id: creative.descendant_ids)  # 이 creative의 strict descendants에 있는 share들
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

      return if ids_to_update.empty?

      permission_value = CreativeShare.permissions[permission]

      # Handle NULL user_id (public shares) separately since SQLite treats NULL as distinct in unique indexes
      if user_id.nil?
        ids_to_update.each do |cid|
          CreativeSharesCache.find_or_initialize_by(creative_id: cid, user_id: nil).tap do |cache|
            cache.assign_attributes(
              permission: permission_value,
              source_share_id: creative_share.id
            )
            cache.save!
          end
        end
      else
        records = ids_to_update.map do |cid|
          {
            creative_id: cid,
            user_id: user_id,
            permission: permission_value,
            source_share_id: creative_share.id
          }
        end

        # Single bulk operation instead of N individual saves
        CreativeSharesCache.upsert_all(
          records,
          unique_by: [ :creative_id, :user_id ],
          update_only: [ :permission, :source_share_id ]
        )
      end
    end

    # CreativeShare 삭제 시 호출
    def self.remove_share(creative_share)
      CreativeSharesCache.where(source_share_id: creative_share.id).delete_all

      # 삭제 후 조상에서 다른 share가 있으면 다시 전파
      rebuild_from_ancestors(creative_share.creative, creative_share.user_id)
    end

    # Public wrapper for rebuild_from_ancestors (used by PermissionCacheJob)
    def self.rebuild_from_ancestors_for_user(creative, user_id)
      rebuild_from_ancestors(creative, user_id)
    end

    # CreativeShare의 creative_id 또는 user_id 변경 시 이전 위치/사용자에 대해 호출
    # 특정 사용자의 캐시를 서브트리에서 재구축 (조상 + 서브트리 내 직접 share 모두 고려)
    # user_id는 nil (public share)일 수 있음
    def self.rebuild_user_cache_for_subtree(creative, user_id)
      return unless creative

      descendant_ids = [ creative.id ] + creative.descendant_ids

      # 해당 사용자의 캐시만 삭제 (owner entries 유지를 위해 source_share_id가 있는 것만)
      CreativeSharesCache.where(creative_id: descendant_ids, user_id: user_id)
                         .where.not(source_share_id: nil)
                         .delete_all

      # 조상에서 해당 사용자의 share 찾아서 전파
      rebuild_from_ancestors(creative, user_id)

      # 서브트리 내의 해당 사용자 직접 share들도 재적용
      # no_access도 포함 - 캐시에 저장하여 public share를 override
      CreativeShare.where(creative_id: descendant_ids, user_id: user_id)
                   .find_each { |share| propagate_share(share) }
    end

    # Creative parent_id 변경 시 호출
    def self.rebuild_for_creative(creative)
      descendant_ids = creative.self_and_descendant_ids

      # 해당 creative와 자손들의 캐시 삭제 (share 기반만 - owner entries 유지)
      CreativeSharesCache.where(creative_id: descendant_ids)
                         .where.not(source_share_id: nil)
                         .delete_all

      # 새 부모 기준으로 조상 share 전파
      rebuild_from_ancestors_for_subtree(creative)

      # 이동된 서브트리 내의 직접 share들 재적용
      # (closest-share-wins 의미론으로 올바르게 전파됨)
      # no_access도 포함 - 캐시에 저장하여 public share를 override
      CreativeShare.where(creative_id: descendant_ids)
                   .find_each { |share| propagate_share(share) }

      # 소유자 캐시 재확인 (혹시 누락된 경우)
      creative.self_and_descendants.each do |c|
        cache_owner(c) if c.user_id
      end
    end

    class << self
      private

      def rebuild_from_ancestors(creative, user_id)
        # 조상들 중 해당 user에 대한 share 찾기 (가장 가까운 조상 우선)
        # no_access도 포함 - 캐시에 저장하여 public share를 override
        ancestor_ids = creative.ancestor_ids
        return if ancestor_ids.empty?

        ancestor_share = CreativeShare
          .where(creative_id: ancestor_ids, user_id: user_id)
          .joins("INNER JOIN creative_hierarchies ch ON creative_shares.creative_id = ch.ancestor_id")
          .where("ch.descendant_id = ?", creative.id)
          .order("ch.generations ASC")
          .first

        propagate_share(ancestor_share) if ancestor_share
      end

      def rebuild_from_ancestors_for_subtree(creative)
        ancestor_ids = creative.ancestor_ids
        return if ancestor_ids.empty?

        # 조상들의 모든 share 가져오기
        # no_access도 포함 - 캐시에 저장하여 public share를 override
        ancestor_shares = CreativeShare.where(creative_id: ancestor_ids)

        ancestor_shares.each do |share|
          propagate_share(share)
        end
      end
    end
  end
end
