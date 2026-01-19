module Creatives
  class PermissionChecker
    def initialize(creative, user)
      @creative = creative
      @user = user
    end

    def allowed?(required_permission = :read)
      base = creative.origin_id.nil? ? creative : creative.origin

      # Owner always has admin permission (fallback for fixtures and missing cache entries)
      return true if base.user_id == user&.id

      # O(1) 캐시 테이블 조회
      # 소유자도 캐시에 있음 (admin 권한으로)
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

    attr_reader :creative, :user

    def permission_rank(value)
      CreativeShare.permissions[value.to_s]
    end
  end
end
