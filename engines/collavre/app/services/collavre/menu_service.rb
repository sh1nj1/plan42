# frozen_string_literal: true

module Collavre
  class MenuService
    CACHE_KEY = "collavre:menu_tree"

    class << self
      # Build a menu tree from Creative records with kind: "menu"
      # Returns an array of menu item hashes
      def tree(user: Collavre.current_user)
        all_items = cached_tree
        all_items.filter_map { |item| filter_for_user(item, user) }
      end

      # Find menu items for a specific section
      def items_for(section, user: Collavre.current_user)
        tree(user: user).select { |item| item[:section] == section.to_s }
      end

      # Convert menu Creative items to NavigationRegistry format for merging
      def navigation_items_for(section, user: Collavre.current_user)
        items_for(section, user: user).map { |item| to_nav_item(item) }
      end

      # Invalidate cached menu tree
      def invalidate!
        Rails.cache.delete(CACHE_KEY)
      end

      private

      def cached_tree
        Rails.cache.fetch(CACHE_KEY) do
          build_tree
        end
      end

      def build_tree
        roots = Creative.menus
                        .where(parent_id: nil)
                        .includes(:children, :creative_shares)
                        .order(Arel.sql("CAST(json_extract(data, '$.order') AS INTEGER)"))

        roots.map { |creative| build_item(creative) }
      end

      def build_item(creative)
        data = creative.data || {}

        {
          id: creative.id,
          key: data["key"],
          label: data["label"].presence || creative.description&.to_plain_text,
          path: data["path"],
          icon: data["icon"],
          section: data["section"] || "main",
          order: data["order"] || 0,
          permissions: Array(data["permissions"]),
          requires_auth: data["requires_auth"] == true,
          creative_shares: creative.creative_shares.map { |s| { user_id: s.user_id, permission: s.permission } },
          children: build_children(creative)
        }
      end

      def build_children(creative)
        creative.children
                .where(kind: "menu")
                .includes(:creative_shares)
                .order(Arel.sql("CAST(json_extract(data, '$.order') AS INTEGER)"))
                .map { |child| build_item(child) }
      end

      def filter_for_user(item, user)
        return nil unless authorized?(item, user)

        filtered_children = item[:children].filter_map { |child| filter_for_user(child, user) }
        item.merge(children: filtered_children)
      end

      def authorized?(item, user)
        # Admin bypass
        if user&.respond_to?(:system_admin?) && user.system_admin?
          return true
        end

        # Check creative_shares first (more granular)
        shares = item[:creative_shares]
        if shares.present?
          return true if shares.any? { |s| s[:user_id].nil? && s[:permission] != "no_access" } # public share
          return user.present? && shares.any? { |s| s[:user_id] == user.id && s[:permission] != "no_access" }
        end

        # Fall back to data permissions
        permissions = item[:permissions]
        return true if permissions.empty?
        return true if permissions.include?("all")

        return false unless user

        user_roles = ["user"]
        user_roles << "admin" if user.respond_to?(:system_admin?) && user.system_admin?
        (permissions & user_roles).any?
      end

      # Convert a MenuService item to NavigationRegistry format
      def to_nav_item(item)
        nav = {
          key: (item[:key] || "creative_menu_#{item[:id]}").to_sym,
          label: item[:label] || "",
          section: (item[:section] || "main").to_sym,
          priority: item[:order] || 500,
          type: :link,
          path: item[:path],
          desktop: true,
          mobile: true,
          requires_auth: item[:requires_auth] || item[:permissions].any?,
          requires_user: false,
          source: :creative
        }

        nav[:icon] = item[:icon] if item[:icon].present?

        if item[:children].present?
          nav[:children] = item[:children].map { |child| to_nav_item(child) }
        end

        nav
      end
    end
  end
end
