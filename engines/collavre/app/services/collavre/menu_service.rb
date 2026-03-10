module Collavre
  class MenuService
    class << self
      # Build a menu tree from Creative records with kind: "menu"
      # Returns an array of menu item hashes
      def tree(user: Collavre.current_user)
        roots = Creative.menus
                        .where(parent_id: nil)
                        .includes(:children)
                        .order(Arel.sql("CAST(json_extract(data, '$.order') AS INTEGER)"))

        roots.filter_map { |creative| build_item(creative, user) }
      end

      # Find menu items for a specific section
      def items_for(section, user: Collavre.current_user)
        tree(user: user).select { |item| item[:section] == section.to_s }
      end

      # Invalidate cached menu (for future caching)
      def invalidate!
        # Future: Rails.cache.delete("collavre:menu_tree")
      end

      private

      def build_item(creative, user)
        data = creative.data || {}

        permissions = Array(data["permissions"])
        return nil if permissions.any? && !authorized?(permissions, user)

        {
          id: creative.id,
          label: data["label"].presence || creative.description&.to_plain_text,
          path: data["path"],
          icon: data["icon"],
          section: data["section"] || "main",
          order: data["order"] || 0,
          permissions: permissions,
          children: build_children(creative, user)
        }
      end

      def build_children(creative, user)
        creative.children
                .where(kind: "menu")
                .order(Arel.sql("CAST(json_extract(data, '$.order') AS INTEGER)"))
                .filter_map { |child| build_item(child, user) }
      end

      def authorized?(permissions, user)
        return true if user.nil?
        return true if permissions.empty?
        return true if permissions.include?("all")

        user_roles = []
        user_roles << "admin" if user.respond_to?(:system_admin) && user.system_admin?
        user_roles << "user"

        (permissions & user_roles).any?
      end
    end
  end
end
