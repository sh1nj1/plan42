require "test_helper"

module Collavre
  class MenuServiceTest < ActiveSupport::TestCase
    setup do
      @admin = users(:one)
      @regular = users(:two)
      Collavre::Current.user = @admin
    end

    test "tree returns root menu items" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Home", "path" => "/", "order" => 1 },
        user: @admin
      )

      items = MenuService.tree(user: @admin)
      labels = items.map { |i| i[:label] }

      assert_includes labels, "Home"
    end

    test "tree includes children" do
      parent = Creative.create!(
        kind: "menu",
        data: { "label" => "Settings", "path" => "/settings", "order" => 1 },
        user: @admin
      )

      Creative.create!(
        kind: "menu",
        data: { "label" => "Profile", "path" => "/settings/profile", "order" => 1 },
        parent: parent,
        user: @admin
      )

      items = MenuService.tree(user: @admin)
      settings = items.find { |i| i[:label] == "Settings" }

      assert settings, "Settings menu item should exist"
      assert_equal 1, settings[:children].length
      assert_equal "Profile", settings[:children].first[:label]
    end

    test "tree respects ordering" do
      Creative.create!(kind: "menu", data: { "label" => "Second", "path" => "/b", "order" => 2 }, user: @admin)
      Creative.create!(kind: "menu", data: { "label" => "First", "path" => "/a", "order" => 1 }, user: @admin)
      Creative.create!(kind: "menu", data: { "label" => "Third", "path" => "/c", "order" => 3 }, user: @admin)

      items = MenuService.tree(user: @admin)
      menu_labels = items.select { |i| %w[First Second Third].include?(i[:label]) }.map { |i| i[:label] }

      assert_equal %w[ First Second Third ], menu_labels
    end

    test "tree filters by permissions for non-admin" do
      Creative.create!(
        kind: "menu",
        data: { "label" => "Admin Only", "path" => "/admin", "permissions" => [ "admin" ] },
        user: @admin
      )
      Creative.create!(
        kind: "menu",
        data: { "label" => "Public", "path" => "/public", "permissions" => [ "all" ] },
        user: @admin
      )

      admin_items = MenuService.tree(user: @admin)
      admin_labels = admin_items.map { |i| i[:label] }
      assert_includes admin_labels, "Admin Only"
      assert_includes admin_labels, "Public"

      regular_items = MenuService.tree(user: @regular)
      regular_labels = regular_items.map { |i| i[:label] }
      assert_not_includes regular_labels, "Admin Only"
      assert_includes regular_labels, "Public"
    end

    test "tree excludes non-menu creatives" do
      Creative.create!(kind: "menu", data: { "label" => "Menu Item", "path" => "/menu" }, user: @admin)
      Creative.create!(kind: nil, description: "Regular Creative", user: @admin)

      items = MenuService.tree(user: @admin)
      labels = items.map { |i| i[:label] }

      assert_includes labels, "Menu Item"
      assert_not_includes labels, "Regular Creative"
    end

    test "items_for filters by section" do
      Creative.create!(
        kind: "menu",
        data: { "label" => "Sidebar Item", "path" => "/sidebar", "section" => "sidebar" },
        user: @admin
      )
      Creative.create!(
        kind: "menu",
        data: { "label" => "Main Item", "path" => "/main", "section" => "main" },
        user: @admin
      )

      sidebar_items = MenuService.items_for("sidebar", user: @admin)
      sidebar_labels = sidebar_items.map { |i| i[:label] }

      assert_includes sidebar_labels, "Sidebar Item"
      assert_not_includes sidebar_labels, "Main Item"
    end
  end
end
