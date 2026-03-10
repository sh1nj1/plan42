# frozen_string_literal: true

module Collavre
  module Seeds
    class MenuSeeds
      # Example Creative-based menu items.
      # These do NOT overlap with NavigationRegistry items (home, plans, inbox etc.).
      # Registry items use partials/components; Creative menus are simpler link-based items.
      MENU_ITEMS = [].freeze

      def self.seed!
        new.seed!
      end

      def seed!
        system_user = find_system_user
        return unless system_user

        MENU_ITEMS.each do |menu_data|
          seed_menu_item(menu_data, system_user)
        end

        Rails.logger.info "Menu seeds completed (#{MENU_ITEMS.size} items)"
      end

      private

      def find_system_user
        User.find_by(email: "system@collavre.com") || User.first
      end

      def seed_menu_item(menu_data, user)
        existing = Creative.menus.find_by(
          "json_extract(data, '$.key') = ?", menu_data[:key]
        )

        if existing
          existing.update!(data: menu_data.stringify_keys)
          Rails.logger.info "  Updated menu: #{menu_data[:key]}"
        else
          Creative.create!(
            kind: "menu",
            data: menu_data.stringify_keys,
            user: user
          )
          Rails.logger.info "  Created menu: #{menu_data[:key]}"
        end
      end
    end
  end
end
