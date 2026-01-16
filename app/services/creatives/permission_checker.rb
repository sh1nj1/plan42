module Creatives
  class PermissionChecker
    def initialize(creative, user)
      @creative = creative
      @user = user
      @cache = Current.respond_to?(:creative_share_cache) ? Current.creative_share_cache : nil
    end

    def allowed?(required_permission = :read)
      base = creative.origin_id.nil? ? creative : creative.origin

      # 소유자 체크
      return true if base.user_id == user&.id

      # 캐시 테이블에서 O(1) 조회
      # no_access는 캐시에 없으므로 조회 결과가 없으면 = 접근 불가
      user_conditions = user ? [ user.id, nil ] : [ nil ]
      cache_entry = CreativeSharesCache
        .where(creative_id: base.id, user_id: user_conditions)
        .order(permission: :desc)
        .first

      return false unless cache_entry

      permission_rank(cache_entry.permission) >= permission_rank(required_permission)
    end

    private

    attr_reader :creative, :user, :cache

    def permission_rank(value)
      CreativeShare.permissions[value.to_s]
    end
  end
end
