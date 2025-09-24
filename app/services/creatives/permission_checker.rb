module Creatives
  class PermissionChecker
    def initialize(creative, user)
      @creative = creative
      @user = user
      @cache = Current.respond_to?(:creative_share_cache) ? Current.creative_share_cache : nil
    end

    def allowed?(required_permission = :read)
      base = creative.origin_id.nil? ? creative : creative.origin
      allowed_on_tree?(base, required_permission)
    end

    private

    attr_reader :creative, :user, :cache

    def allowed_on_tree?(node, required_permission)
      return true if node.user_id == user&.id

      current = node
      while current
        share = share_for(current)
        if share
          return false if share.permission.to_s == "no_access"

          if permission_rank(share.permission) >= permission_rank(required_permission)
            return true
          end
        end
        current = current.parent
      end
      false
    end

    def share_for(node)
      cache ? cache[node.id] : CreativeShare.find_by(user: user, creative: node)
    end

    def permission_rank(value)
      CreativeShare.permissions[value.to_s]
    end
  end
end
