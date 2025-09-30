module Creatives
  class PermissionChecker
    def initialize(creative, user)
      @creative = creative
      @user = user
      @cache = Current.respond_to?(:creative_share_cache) ? Current.creative_share_cache : nil
      @permission_cache = Current.respond_to?(:creative_permission_cache) ? Current.creative_permission_cache : nil
    end

    def allowed?(required_permission = :read)
      base = creative.origin_id.nil? ? creative : creative.origin

      # Check permission cache first
      if @permission_cache && @user
        cache_key = "#{base.id}_#{@user.id}_#{required_permission}"
        cached_result = @permission_cache[cache_key]
        return cached_result unless cached_result.nil?
      end

      result = allowed_on_tree?(base, required_permission)

      # Store result in cache
      if @permission_cache && @user
        cache_key = "#{base.id}_#{@user.id}_#{required_permission}"
        @permission_cache[cache_key] = result
      end

      result
    end

    private

    attr_reader :creative, :user, :cache, :permission_cache

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
