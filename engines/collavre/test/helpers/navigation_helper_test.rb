# frozen_string_literal: true

require "test_helper"

class NavigationHelperTest < ActionView::TestCase
  include Collavre::NavigationHelper
  include ApplicationHelper

  setup do
    Navigation::Registry.instance.reset!
  end

  teardown do
    Navigation::Registry.instance.reset!
  end

  # Stub authentication methods
  def authenticated?
    @authenticated ||= false
  end

  def authenticated=(value)
    @authenticated = value
  end

  test "navigation_items_for returns items for section" do
    Navigation::Registry.instance.register(key: :item1, label: "Item 1", section: :main)
    Navigation::Registry.instance.register(key: :item2, label: "Item 2", section: :user)

    main_items = navigation_items_for(:main)
    assert_equal 1, main_items.size
    assert_equal :item1, main_items.first[:key]
  end

  test "navigation_items_for filters by desktop visibility" do
    Navigation::Registry.instance.register(key: :desktop_only, label: "Desktop", desktop: true, mobile: false)
    Navigation::Registry.instance.register(key: :mobile_only, label: "Mobile", desktop: false, mobile: true)
    Navigation::Registry.instance.register(key: :both, label: "Both", desktop: true, mobile: true)

    desktop_items = navigation_items_for(:main, desktop: true)
    assert_equal 2, desktop_items.size
    assert_includes desktop_items.map { |i| i[:key] }, :desktop_only
    assert_includes desktop_items.map { |i| i[:key] }, :both

    mobile_items = navigation_items_for(:main, desktop: false)
    assert_equal 2, mobile_items.size
    assert_includes mobile_items.map { |i| i[:key] }, :mobile_only
    assert_includes mobile_items.map { |i| i[:key] }, :both
  end

  test "navigation_item_visible? respects requires_auth" do
    item = { key: :test, label: "Test", requires_auth: true, desktop: true, mobile: true }

    @authenticated = false
    assert_not navigation_item_visible?(item, desktop: true)

    @authenticated = true
    assert navigation_item_visible?(item, desktop: true)
  end

  test "navigation_item_visible? respects requires_user" do
    item = { key: :test, label: "Test", requires_user: true, desktop: true, mobile: true }

    Current.user = nil
    assert_not navigation_item_visible?(item, desktop: true)

    Current.user = users(:one)
    assert navigation_item_visible?(item, desktop: true)
  ensure
    Current.user = nil
  end

  test "navigation_item_visible? evaluates visibility proc" do
    visible_item = { key: :test, label: "Test", visible: -> { true }, desktop: true, mobile: true }
    hidden_item = { key: :test, label: "Test", visible: -> { false }, desktop: true, mobile: true }

    assert navigation_item_visible?(visible_item, desktop: true)
    assert_not navigation_item_visible?(hidden_item, desktop: true)
  end

  test "resolve_nav_value evaluates procs" do
    proc_value = -> { "evaluated" }
    static_value = "static"

    assert_equal "evaluated", resolve_nav_value(proc_value)
    assert_equal "static", resolve_nav_value(static_value)
  end

  test "render_navigation_item renders button type" do
    Navigation::Registry.instance.register(
      key: :test,
      label: "Test Button",
      type: :button,
      path: -> { "/" }
    )

    item = Navigation::Registry.instance.find(:test)
    html = render_navigation_item(item)

    assert_match(/Test Button/, html)
    assert_match(/button/, html)
  end

  test "render_navigation_item renders link type" do
    Navigation::Registry.instance.register(
      key: :test,
      label: "Test Link",
      type: :link,
      path: -> { "/" }
    )

    item = Navigation::Registry.instance.find(:test)
    html = render_navigation_item(item)

    assert_match(/Test Link/, html)
    assert_match(/href/, html)
  end

  test "render_navigation_item renders partial type" do
    Navigation::Registry.instance.register(
      key: :test,
      label: "Test",
      type: :partial,
      partial: "collavre/shared/navigation/help_button"
    )

    item = Navigation::Registry.instance.find(:test)
    html = render_navigation_item(item)

    assert_match(/creative-guide-link/, html)
  end

  test "render_mobile_navigation_item wraps in div" do
    Navigation::Registry.instance.register(
      key: :test,
      label: "Test Button",
      type: :button,
      path: -> { "/" }
    )

    item = Navigation::Registry.instance.find(:test)
    html = render_mobile_navigation_item(item)

    assert_match(/<div>/, html)
    assert_match(/Test Button/, html)
  end

  test "render_navigation_item respects html_class option" do
    Navigation::Registry.instance.register(
      key: :test,
      label: "Test",
      type: :button,
      path: -> { "/" },
      html_class: "custom-class"
    )

    item = Navigation::Registry.instance.find(:test)
    html = render_navigation_item(item)

    assert_match(/custom-class/, html)
  end

  test "render_navigation_item respects html_id option" do
    Navigation::Registry.instance.register(
      key: :test,
      label: "Test",
      type: :button,
      path: -> { "/" },
      html_id: "custom-id"
    )

    item = Navigation::Registry.instance.find(:test)
    html = render_navigation_item(item)

    assert_match(/custom-id/, html)
  end

  test "render_navigation_item renders divider type" do
    Navigation::Registry.instance.register(
      key: :test,
      label: "divider",
      type: :divider
    )

    item = Navigation::Registry.instance.find(:test)
    html = render_navigation_item(item)

    assert_match(/<hr/, html)
  end

  test "resolve_nav_label translates i18n keys" do
    label = send(:resolve_nav_label, "app.home")
    assert_equal I18n.t("app.home"), label
  end

  test "resolve_nav_label returns plain strings" do
    label = send(:resolve_nav_label, "Plain Text")
    assert_equal "Plain Text", label
  end

  test "deep_resolve_procs resolves nested procs in arrays" do
    input = [
      { name: -> { "Resolved" }, value: :test },
      { name: "Static", value: :static }
    ]

    result = send(:deep_resolve_procs, input)

    assert_equal "Resolved", result[0][:name]
    assert_equal "Static", result[1][:name]
  end

  test "deep_resolve_procs resolves nested procs in hashes" do
    input = {
      outer: {
        inner: -> { "Deep Value" }
      }
    }

    result = send(:deep_resolve_procs, input)

    assert_equal "Deep Value", result[:outer][:inner]
  end

  test "render_nav_raw escapes untrusted content" do
    Navigation::Registry.instance.register(
      key: :test_raw,
      label: "raw",
      type: :raw,
      content: -> { "<script>alert('xss')</script>" }
    )

    item = Navigation::Registry.instance.find(:test_raw)
    html = send(:render_nav_raw, item)

    assert_not_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  end

  test "render_nav_raw preserves html_safe content" do
    Navigation::Registry.instance.register(
      key: :test_raw_safe,
      label: "raw",
      type: :raw,
      content: -> { "<strong>Safe</strong>".html_safe }
    )

    item = Navigation::Registry.instance.find(:test_raw_safe)
    html = send(:render_nav_raw, item)

    assert_includes html, "<strong>Safe</strong>"
  end

  test "render_nav_raw handles nil content" do
    Navigation::Registry.instance.register(
      key: :test_raw_nil,
      label: "raw",
      type: :raw,
      content: -> { nil }
    )

    item = Navigation::Registry.instance.find(:test_raw_nil)
    html = send(:render_nav_raw, item)

    assert_equal "", html
  end

  test "render_navigation_item renders popup type as dropdown" do
    Navigation::Registry.instance.register(
      key: :test_popup,
      label: "Popup Menu",
      type: :popup,
      align: :right,
      children: [
        { key: :child1, label: "Child 1", type: :link, path: -> { "/path1" } },
        { key: :child2, label: "Child 2", type: :link, path: -> { "/path2" } }
      ]
    )

    item = Navigation::Registry.instance.find(:test_popup)
    html = render_navigation_item(item)

    assert_match(/Popup Menu/, html)
    assert_match(/Child 1/, html)
    assert_match(/Child 2/, html)
  end
end
