module Creatives
  class PermissionChecker
    def initialize(creative, user)
      @creative = creative
      @user = user
      @cache = Current.respond_to?(:creative_share_cache) ? Current.creative_share_cache : nil
    end

    def allowed?(required_permission = :read)
      base = creative.origin_id.nil? ? creative : creative.origin

      # Check application-wide permission cache first
      if @user
        cache_key = "creative_permission:#{base.cache_key_with_version}:#{@user.id}:#{required_permission}"
        cached_result = Rails.cache.read(cache_key)
        return cached_result unless cached_result.nil?
      end

      result = allowed_on_tree?(base, required_permission)

      # Store result in application-wide cache
      if @user
        cache_key = "creative_permission:#{base.cache_key_with_version}:#{@user.id}:#{required_permission}"
        Rails.cache.write(cache_key, result, expires_in: Rails.application.config.permission_cache_expires_in)
      end

      result
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
      user_share = if cache
                     cache[node.id]
      elsif user
                     CreativeShare.find_by(user: user, creative: node)
      end

      public_share = CreativeShare.find_by(creative: node, user: nil)

      return user_share unless public_share
      return public_share unless user_share

      # Return the one with higher permission
      if permission_rank(user_share.permission) >= permission_rank(public_share.permission)
        user_share
      else
        public_share
      end
    end

    def permission_rank(value)
      CreativeShare.permissions[value.to_s]
    end
  end
end
