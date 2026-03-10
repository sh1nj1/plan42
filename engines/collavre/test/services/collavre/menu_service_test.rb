require "test_helper"

module Collavre
  class MenuServiceTest < ActiveSupport::TestCase
    setup do
      @admin = users(:one)
      @regular = users(:two)
      Collavre::Current.user = @admin
      Collavre::MenuService.invalidate!
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

    test "tree caches results" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Cached Item", "path" => "/cached", "order" => 1 },
        user: @admin
      )

      # First call - not cached
      items1 = MenuService.tree(user: @admin)
      assert_includes items1.map { |i| i[:label] }, "Cached Item"

      # Second call - should hit cache
      items2 = MenuService.tree(user: @admin)
      assert_includes items2.map { |i| i[:label] }, "Cached Item"

      # Verify cache is being used by checking it exists
      cache_key = Collavre::MenuService::CACHE_KEY
      assert Rails.cache.exist?(cache_key)
    end

    test "invalidate! clears cache" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Test Item", "path" => "/test", "order" => 1 },
        user: @admin
      )

      # Populate cache
      MenuService.tree(user: @admin)
      cache_key = Collavre::MenuService::CACHE_KEY
      assert Rails.cache.exist?(cache_key)

      # Invalidate
      MenuService.invalidate!

      # Cache should be cleared
      assert_not Rails.cache.exist?(cache_key)
    end

    test "cache is invalidated when menu Creative is saved" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Original", "path" => "/original", "order" => 1 },
        user: @admin
      )

      # Populate cache
      MenuService.tree(user: @admin)
      cache_key = Collavre::MenuService::CACHE_KEY
      assert Rails.cache.exist?(cache_key)

      # Update menu
      menu.update!(data: { "label" => "Updated", "path" => "/updated", "order" => 1 })

      # Cache should be cleared
      assert_not Rails.cache.exist?(cache_key)
    end

    test "cache is invalidated when menu Creative is destroyed" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "To Delete", "path" => "/delete", "order" => 1 },
        user: @admin
      )

      # Populate cache
      MenuService.tree(user: @admin)
      cache_key = Collavre::MenuService::CACHE_KEY
      assert Rails.cache.exist?(cache_key)

      # Delete menu
      menu.destroy!

      # Cache should be cleared
      assert_not Rails.cache.exist?(cache_key)
    end

    test "authorized? checks creative_shares when shares exist" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Shared Menu", "path" => "/shared", "order" => 1 },
        user: @admin
      )

      # Create a share for the regular user
      CreativeShare.create!(
        creative: menu,
        user: @regular,
        shared_by: @admin,
        permission: :read
      )

      items = MenuService.tree(user: @regular)
      labels = items.map { |i| i[:label] }

      assert_includes labels, "Shared Menu"
    end

    test "authorized? respects no_access permission in creative_shares" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Restricted Menu", "path" => "/restricted", "order" => 1 },
        user: @admin
      )

      # Create a no_access share for the regular user
      CreativeShare.create!(
        creative: menu,
        user: @regular,
        shared_by: @admin,
        permission: :no_access
      )

      items = MenuService.tree(user: @regular)
      labels = items.map { |i| i[:label] }

      assert_not_includes labels, "Restricted Menu"
    end

    test "authorized? falls back to data permissions when no shares exist" do
      Creative.create!(
        kind: "menu",
        data: { "label" => "User Menu", "path" => "/user", "order" => 1, "permissions" => ["user"] },
        user: @admin
      )

      items = MenuService.tree(user: @regular)
      labels = items.map { |i| i[:label] }

      assert_includes labels, "User Menu"
    end

    test "navigation_items_for converts to NavigationRegistry format" do
      Creative.create!(
        kind: "menu",
        data: { "key" => "dashboard", "label" => "Dashboard", "path" => "/dashboard", "section" => "main", "order" => 100, "icon" => "home" },
        user: @admin
      )

      nav_items = MenuService.navigation_items_for("main", user: @admin)
      dashboard = nav_items.find { |i| i[:key] == :dashboard }

      assert dashboard, "Dashboard nav item should exist"
      assert_equal "Dashboard", dashboard[:label]
      assert_equal "/dashboard", dashboard[:path]
      assert_equal :main, dashboard[:section]
      assert_equal 100, dashboard[:priority]
      assert_equal :link, dashboard[:type]
      assert_equal "home", dashboard[:icon]
      assert_equal :creative, dashboard[:source]
    end

    test "navigation_items_for uses creative_menu_ID as key when no key in data" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "No Key", "path" => "/nokey", "section" => "main" },
        user: @admin
      )

      nav_items = MenuService.navigation_items_for("main", user: @admin)
      item = nav_items.find { |i| i[:key] == :"creative_menu_#{menu.id}" }

      assert item, "Nav item should use creative_menu_ID as key"
    end

    test "admin users bypass all permission checks" do
      menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Admin Only", "path" => "/admin", "order" => 1, "permissions" => ["admin"] },
        user: @admin
      )

      admin_items = MenuService.tree(user: @admin)
      admin_labels = admin_items.map { |i| i[:label] }

      assert_includes admin_labels, "Admin Only"
    end
  end
end
