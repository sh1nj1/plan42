# frozen_string_literal: true

module Collavre
  module Seeds
    class MenuSeeds
      MENU_ITEMS = [
        {
          key: "home",
          label: "Home",
          path: "/",
          icon: "home",
          section: "main",
          order: 110
        },
        {
          key: "plans",
          label: "Plans",
          path: "/plans",
          icon: "folder",
          section: "main",
          order: 120,
          permissions: ["user"],
          requires_auth: true
        },
        {
          key: "inbox",
          label: "Inbox",
          path: "/inbox",
          icon: "inbox",
          section: "main",
          order: 150,
          permissions: ["user"],
          requires_auth: true
        }
      ].freeze

      def self.seed!
        new.seed!
      end

      def seed!
        system_user = find_system_user
        return unless system_user

        MENU_ITEMS.each do |menu_data|
          seed_menu_item(menu_data, system_user)
        end

        Rails.logger.info "Menu seeds created successfully"
      end

      private

      def find_system_user
        User.find_by(email: "system@collavre.com") || User.first
      end

      def seed_menu_item(menu_data, user)
        # Find by key in JSON data column
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
