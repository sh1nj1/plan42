module Collavre
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
        # 사용자별 엔트리를 먼저 확인 (no_access가 public share보다 우선)
        if user
          user_entry = CreativeSharesCache.find_by(creative_id: base.id, user_id: user.id)
          if user_entry
            # no_access는 명시적 거부 - public share가 있어도 차단
            return false if user_entry.no_access?
            return permission_rank(user_entry.permission) >= permission_rank(required_permission)
          end
        end

        # 사용자별 엔트리 없으면 public share 확인
        public_entry = CreativeSharesCache.find_by(creative_id: base.id, user_id: nil)
        return false unless public_entry

        permission_rank(public_entry.permission) >= permission_rank(required_permission)
      end

      private

      attr_reader :creative, :user

      def permission_rank(value)
        CreativeShare.permissions[value.to_s]
      end
    end
  end
end
