module Collavre
  module Creatives
    class PermissionChecker
      # Handoff cannot wait for asynchronous PermissionCacheJob propagation.
      # Keep the same owner/user/public precedence, but resolve current shares
      # in the authoritative hierarchy and bypass the worker's SQL query cache.
      def self.current_allowed?(creative_id, user, required_permission = :read)
        Creative.uncached do
          creative = Creative.find_by(id: creative_id)
          creative.present? && new(creative, user, current_shares: true).allowed?(required_permission)
        end
      end

      def initialize(creative, user, current_shares: false)
        @creative = creative
        @user = user
        @current_shares = current_shares
      end

      def allowed?(required_permission = :read)
        base = EffectiveCreativeResolution.effective_creative(creative)

        # Owner always has admin permission (fallback for fixtures and missing cache entries)
        return true if base.user_id == user&.id

        # O(1) 캐시 테이블 조회
        # 사용자별 엔트리를 먼저 확인 (no_access가 public share보다 우선)
        if user
          user_entry = entry_for(base, user.id)
          if user_entry
            # no_access는 명시적 거부 - public share가 있어도 차단
            return false if user_entry.no_access?
            return permission_rank(user_entry.permission) >= permission_rank(required_permission)
          end
        end

        # 사용자별 엔트리 없으면 public share 확인
        public_entry = entry_for(base, nil)
        return false unless public_entry

        permission_rank(public_entry.permission) >= permission_rank(required_permission)
      end

      private

      attr_reader :creative, :user

      def entry_for(base, user_id)
        return CreativeSharesCache.find_by(creative_id: base.id, user_id: user_id) unless @current_shares

        # Closest share wins independently for this user and the public.
        # The closure table includes the creative itself at generation zero.
        CreativeShare.where(user_id: user_id)
          .joins("INNER JOIN creative_hierarchies ch ON creative_shares.creative_id = ch.ancestor_id")
          .where("ch.descendant_id = ?", base.id).order("ch.generations ASC").first
      end

      def permission_rank(value)
        CreativeShare.permissions[value.to_s]
      end
    end
  end
end
