require "test_helper"

module Collavre
  class CreativeKindTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      Collavre::Current.user = @user
    end

    # --- kind validation ---

    test "valid kinds are accepted" do
      Creative::KINDS.each do |kind|
        creative = Creative.new(description: "test", kind: kind, user: @user)
        creative.valid?
        assert_not creative.errors[:kind].any?, "kind '#{kind}' should be valid"
      end
    end

    test "nil kind is accepted (default creative)" do
      creative = Creative.new(description: "test", kind: nil, user: @user)
      creative.valid?
      assert_not creative.errors[:kind].any?
    end

    test "invalid kind is rejected" do
      creative = Creative.new(description: "test", kind: "invalid_type", user: @user)
      assert_not creative.valid?
      assert creative.errors[:kind].any?
    end

    # --- scope ---

    test "of_kind scope filters by kind" do
      menu = Creative.create!(description: "Menu Item", kind: "menu", data: { "label" => "Home", "path" => "/" }, user: @user)
      normal = Creative.create!(description: "Normal", user: @user)

      assert_includes Creative.of_kind("menu"), menu
      assert_not_includes Creative.of_kind("menu"), normal
    end

    test "menus scope returns menu kind" do
      menu = Creative.create!(description: "Menu", kind: "menu", data: { "label" => "Home", "path" => "/" }, user: @user)

      assert_includes Creative.menus, menu
    end

    # --- menu renderer ---

    test "menu kind renders description from data on save" do
      creative = Creative.create!(
        kind: "menu",
        data: { "label" => "Dashboard", "path" => "/dashboard", "icon" => "🏠" },
        user: @user
      )

      assert_includes creative.description, "Dashboard"
      assert_includes creative.description, "/dashboard"
    end

    test "menu renderer includes permissions" do
      creative = Creative.create!(
        kind: "menu",
        data: { "label" => "Admin Panel", "path" => "/admin", "permissions" => [ "admin" ] },
        user: @user
      )

      assert_includes creative.description, "Admin Panel"
      assert_includes creative.description, "admin"
    end

    test "menu renderer with icon" do
      creative = Creative.create!(
        kind: "menu",
        data: { "label" => "Projects", "path" => "/projects", "icon" => "📁" },
        user: @user
      )

      assert_includes creative.description, "📁"
      assert_includes creative.description, "Projects"
    end

    # --- data change triggers re-render ---

    test "updating data re-renders description" do
      creative = Creative.create!(
        kind: "menu",
        data: { "label" => "Old Label", "path" => "/old" },
        user: @user
      )

      assert_includes creative.description, "Old Label"

      creative.update!(data: { "label" => "New Label", "path" => "/new" })
      creative.reload

      assert_includes creative.description, "New Label"
      assert_not_includes creative.description, "Old Label"
    end

    test "direct description edit is overridden by renderer when kind is set" do
      creative = Creative.create!(
        kind: "menu",
        data: { "label" => "Dashboard", "path" => "/" },
        user: @user
      )

      rendered = creative.description
      assert_includes rendered, "Dashboard"

      # Attempt to directly edit description
      creative.update!(description: "<p>Hacked description</p>")
      creative.reload

      # Renderer should have overwritten the direct edit
      assert_includes creative.description, "Dashboard"
      assert_not_includes creative.description, "Hacked"
    end

    # --- nil kind does not render ---

    test "nil kind does not override description from data" do
      creative = Creative.create!(
        description: "Manual description",
        kind: nil,
        data: { "some" => "data" },
        user: @user
      )

      assert_equal "Manual description", creative.description
    end

    # --- linked creative inherits data ---

    test "linked creative effective_attribute returns origin data" do
      origin = Creative.create!(
        kind: "menu",
        data: { "label" => "Origin Menu", "path" => "/origin" },
        user: @user
      )

      linked = Creative.create!(
        origin_id: origin.id,
        user: @user
      )

      assert_equal origin.data, linked.effective_attribute(:data)
    end

    # --- menu tree structure ---

    test "menu creative with children creates tree" do
      parent_menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Settings", "path" => "/settings", "order" => 1 },
        user: @user
      )

      child_menu = Creative.create!(
        kind: "menu",
        data: { "label" => "Profile", "path" => "/settings/profile", "order" => 1 },
        parent: parent_menu,
        user: @user
      )

      assert_equal parent_menu.id, child_menu.parent_id
      assert_includes parent_menu.children, child_menu
    end
  end
end
