module Creatives
  class InheritedShareBuilder
    # CreativeShare가 생성될 때 호출 (inherited: false인 경우만)
    # 해당 Creative의 모든 자손에 대해 inherited: true인 CreativeShare 생성
    def self.propagate_share(creative_share)
      return if creative_share.inherited?

      creative = creative_share.creative
      user_id = creative_share.user_id
      permission = creative_share.permission

      # 모든 자손 찾기 (실제 + 가상)
      descendant_ids = descendant_ids_for(creative)
      return if descendant_ids.empty?

      now = Time.current
      entries = descendant_ids.map do |descendant_id|
        {
          creative_id: descendant_id,
          user_id: user_id,
          permission: permission,
          inherited: true,
          created_at: now,
          updated_at: now
        }
      end

      # 이미 존재하는 share는 건너뛰기
      CreativeShare.upsert_all(entries, unique_by: [ :creative_id, :user_id ]) if entries.any?
    end

    # CreativeShare가 삭제될 때 호출
    def self.remove_inherited_shares(creative_share)
      return if creative_share.inherited?

      creative = creative_share.creative
      user_id = creative_share.user_id

      descendant_ids = descendant_ids_for(creative)
      return if descendant_ids.empty?

      CreativeShare.where(
        creative_id: descendant_ids,
        user_id: user_id,
        inherited: true
      ).delete_all
    end

    # CreativeShare가 업데이트될 때 호출 (permission 변경)
    def self.update_inherited_shares(creative_share)
      return if creative_share.inherited?

      creative = creative_share.creative
      user_id = creative_share.user_id
      permission = creative_share.permission

      descendant_ids = descendant_ids_for(creative)
      return if descendant_ids.empty?

      CreativeShare.where(
        creative_id: descendant_ids,
        user_id: user_id,
        inherited: true
      ).update_all(permission: permission)
    end

    # 새 Creative가 생성될 때 호출
    # 부모에게 공유된 사용자들에 대해 inherited share 생성
    def self.propagate_to_new_creative(creative)
      return unless creative.parent_id

      # 부모의 모든 share 찾기 (직접 공유 + 상속된 공유)
      parent_shares = CreativeShare.where(creative_id: creative.parent_id)
      return if parent_shares.empty?

      now = Time.current
      entries = parent_shares.map do |share|
        {
          creative_id: creative.id,
          user_id: share.user_id,
          permission: share.permission,
          inherited: true,
          created_at: now,
          updated_at: now
        }
      end

      CreativeShare.upsert_all(entries, unique_by: [ :creative_id, :user_id ]) if entries.any?
    end

    # Creative가 삭제될 때 호출
    def self.remove_shares_for_creative(creative)
      CreativeShare.where(creative_id: creative.id, inherited: true).delete_all
    end

    private

    def self.descendant_ids_for(creative)
      real_descendants = CreativeHierarchy
        .where(ancestor_id: creative.id)
        .where.not(descendant_id: creative.id)
        .pluck(:descendant_id)

      virtual_descendants = VirtualCreativeHierarchy
        .where(ancestor_id: creative.id)
        .pluck(:descendant_id)

      (real_descendants + virtual_descendants).uniq
    end
  end
end
