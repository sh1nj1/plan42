# frozen_string_literal: true

require "test_helper"

class NavigationHelperTest < ActionView::TestCase
  include Collavre::NavigationHelper
  include ApplicationHelper

  # The registry is a process-wide singleton seeded by the engine initializer,
  # so resetting it without putting the engine's items back leaves every later
  # test in the process with an empty GNB.
  setup do
    @registry_snapshot = Navigation::Registry.instance.all
    Navigation::Registry.instance.reset!
  end

  teardown do
    Navigation::Registry.instance.reset!
    @registry_snapshot.each { |item| Navigation::Registry.instance.register(item) }
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

  test "help partial opens the default features page in the current window" do
    SystemSetting.stub(:help_menu_link, "") do
      I18n.with_locale(:en) { render partial: "collavre/shared/navigation/help_button" }
    end

    assert_select "a#creative-guide-link[href='/features?locale=en']", count: 1
    assert_select "a#creative-guide-link[target]", count: 0
  end

  test "help partial preserves the engine mount path" do
    request.script_name = "/collavre"

    SystemSetting.stub(:help_menu_link, "") do
      I18n.with_locale(:ko) { render partial: "collavre/shared/navigation/help_button" }
    end

    assert_select "a#creative-guide-link[href='/collavre/features?locale=ko']", count: 1
  end

  test "help partial opens a configured off-site link in a new tab" do
    SystemSetting.stub(:help_menu_link, "https://docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[href='https://docs.example.com/help']", count: 1
    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured same-host link in the current window" do
    SystemSetting.stub(:help_menu_link, "http://#{request.host}/docs") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[href='http://#{request.host}/docs']", count: 1
    assert_select "a#creative-guide-link[target]", count: 0
  end

  test "help partial opens a configured same-host link on another port in a new tab" do
    SystemSetting.stub(:help_menu_link, "http://#{request.host}:4000/docs") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured same-host link on another scheme in a new tab" do
    SystemSetting.stub(:help_menu_link, "https://#{request.host}/docs") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured scheme-relative same-origin link in the current window" do
    SystemSetting.stub(:help_menu_link, "//#{request.host}/docs") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  # A scheme-relative URL inherits our scheme but not our port: the browser
  # resolves "//host/docs" to the scheme's default port, so served on 4000 this
  # link lands on port 80 — a different service.
  test "help partial opens a configured scheme-relative link in a new tab when we run on a non-default port" do
    request.host = "#{request.host}:4000"

    SystemSetting.stub(:help_menu_link, "//#{request.host}/docs") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured scheme-relative link carrying our non-default port in the current window" do
    request.host = "#{request.host}:4000"

    SystemSetting.stub(:help_menu_link, "//#{request.host}:4000/docs") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  test "help partial opens a configured relative link in the current window" do
    SystemSetting.stub(:help_menu_link, "/docs/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[href='/docs/help']", count: 1
    assert_select "a#creative-guide-link[target]", count: 0
  end

  test "help partial treats an unparseable relative configured link as internal" do
    SystemSetting.stub(:help_menu_link, "/docs/hel lo") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  # URI.parse rejects these; browsers do not. An internationalized domain is
  # punycoded and navigated to, so treating it as ours would replace the app
  # with an off-site page.
  test "help partial opens an unparseable configured link with a scheme in a new tab" do
    SystemSetting.stub(:help_menu_link, "http://exa mple.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured internationalized domain in a new tab" do
    SystemSetting.stub(:help_menu_link, "https://münich.example/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a scheme-relative internationalized domain in a new tab" do
    SystemSetting.stub(:help_menu_link, "//münich.example/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # Ruby finds no host past the extra slashes; a browser skips them and lands on
  # docs.example.com.
  test "help partial opens a configured link with extra leading slashes in a new tab" do
    SystemSetting.stub(:help_menu_link, "///docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured link with a scheme and extra slashes in a new tab" do
    SystemSetting.stub(:help_menu_link, "http:///docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # A browser repairs the missing slash and lands on docs.example.com, because
  # the scheme is not the one this page was served over.
  test "help partial opens a configured link with a foreign scheme and a missing slash in a new tab" do
    SystemSetting.stub(:help_menu_link, "https:/docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens an unparseable link with a foreign scheme and a missing slash in a new tab" do
    SystemSetting.stub(:help_menu_link, "https:/münich.example/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # Same spelling, our own scheme: a browser reads the rest as a path on our
  # origin rather than as a host.
  test "help partial keeps a configured link with our scheme and a missing slash in the current window" do
    SystemSetting.stub(:help_menu_link, "http:/docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  # For a special scheme a browser reads "\" as "/", so two of them open an
  # authority just as "//" does.
  test "help partial opens a configured backslash authority in a new tab" do
    SystemSetting.stub(:help_menu_link, "\\\\docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured mixed slash authority in a new tab" do
    SystemSetting.stub(:help_menu_link, "/\\docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # One backslash is a path separator, not an authority.
  test "help partial keeps a configured single backslash path in the current window" do
    SystemSetting.stub(:help_menu_link, "\\docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  # A browser strips the padding and navigates off-site; comparing the raw
  # string would measure something it never sees.
  test "help partial opens a configured off-site link padded with whitespace in a new tab" do
    SystemSetting.stub(:help_menu_link, "  https://docs.example.com/help  ") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # Tabs and newlines are removed wherever they sit, so this is an off-site URL.
  test "help partial opens a configured off-site link split by a tab in a new tab" do
    SystemSetting.stub(:help_menu_link, "ht\ttps://docs.example.com/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial keeps a configured relative link padded with whitespace in the current window" do
    SystemSetting.stub(:help_menu_link, " /docs/help ") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  # URI::InvalidComponentError is not a URI::InvalidURIError. Letting it escape
  # would raise on every page that carries the navigation.
  test "help partial renders a configured link that raises an invalid component error" do
    SystemSetting.stub(:help_menu_link, "mailto://support@example.com") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # "about:blank" replaces the page with an empty document. Navigating there in
  # place leaves nothing to click, which is the one outcome the current-window
  # switch has to avoid.
  test "help partial opens a configured about link in a new tab" do
    SystemSetting.stub(:help_menu_link, "about:blank") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  test "help partial opens a configured blob link in a new tab" do
    SystemSetting.stub(:help_menu_link, "blob:https://docs.example.com/1234") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # URI.parse raises on this one, so it arrives through the rescue.
  test "help partial opens a configured data link in a new tab" do
    SystemSetting.stub(:help_menu_link, "data:text/html,<h1>help</h1>") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # "file:///x" already reads as an authority; a single slash does not.
  test "help partial opens a configured single slash file link in a new tab" do
    SystemSetting.stub(:help_menu_link, "file:/Users/me/docs.html") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target='_blank'][rel='noopener']", count: 1
  end

  # A handler scheme hands the URL to something else and leaves the page alone,
  # so there is nothing to escape from and no tab to open.
  test "help partial keeps a configured mailto link in the current window" do
    SystemSetting.stub(:help_menu_link, "mailto:support@example.com") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  # The scheme match is anchored to a colon, so a path that merely starts with
  # one of those words is still a path.
  test "help partial keeps a configured relative link starting with a scheme word in the current window" do
    SystemSetting.stub(:help_menu_link, "/about-us/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[target]", count: 0
  end

  # A scheme that executes is never rendered, in any window. Opening a new tab
  # would not defuse it: that tab starts on an about:blank carrying our origin.
  test "help partial drops a configured javascript link for the built-in guide" do
    SystemSetting.stub(:help_menu_link, "javascript:fetch('/evil')") do
      I18n.with_locale(:en) { render partial: "collavre/shared/navigation/help_button" }
    end

    assert_select "a#creative-guide-link[href='/features?locale=en']", count: 1
    assert_select "a#creative-guide-link[target]", count: 0
  end

  test "help partial drops a configured javascript link written in mixed case" do
    SystemSetting.stub(:help_menu_link, "JaVaScRiPt:fetch('/evil')") do
      I18n.with_locale(:en) { render partial: "collavre/shared/navigation/help_button" }
    end

    assert_select "a#creative-guide-link[href='/features?locale=en']", count: 1
  end

  # A browser drops the tab before it reads the scheme, so the check has to run
  # on the normalized value rather than on what was saved.
  test "help partial drops a configured javascript link split by a tab" do
    SystemSetting.stub(:help_menu_link, "java\tscript:fetch('/evil')") do
      I18n.with_locale(:en) { render partial: "collavre/shared/navigation/help_button" }
    end

    assert_select "a#creative-guide-link[href='/features?locale=en']", count: 1
  end

  test "help partial drops a configured vbscript link for the built-in guide" do
    SystemSetting.stub(:help_menu_link, "vbscript:msgbox(1)") do
      I18n.with_locale(:en) { render partial: "collavre/shared/navigation/help_button" }
    end

    assert_select "a#creative-guide-link[href='/features?locale=en']", count: 1
  end

  # The match is anchored to the colon here too: a path may be named after the
  # language without being written in it.
  test "help partial keeps a configured path named after a script language" do
    SystemSetting.stub(:help_menu_link, "/javascript-guide/help") do
      render partial: "collavre/shared/navigation/help_button"
    end

    assert_select "a#creative-guide-link[href='/javascript-guide/help']", count: 1
    assert_select "a#creative-guide-link[target]", count: 0
  end

  test "navigation partial renders mobile guest help and sign in buttons" do
    Navigation::Registry.instance.register(
      key: :help,
      label: "app.help",
      type: :partial,
      partial: "collavre/shared/navigation/help_button",
      priority: 170,
      mobile: true
    )

    Navigation::Registry.instance.register(
      key: :sign_in,
      label: "app.sign_in",
      type: :button,
      path: -> { collavre.new_session_path },
      priority: 160,
      visible: -> { true }
    )

    SystemSetting.stub(:help_menu_link, "") do
      render partial: "collavre/shared/navigation"
    end

    assert_includes rendered, 'class="mobile-only"'
    assert_includes rendered, 'creative-guide-link'
    assert_not_includes rendered, 'target="_blank"'
    assert_includes rendered, I18n.t("app.sign_in")
    assert_includes rendered, collavre.new_session_path
  end

  test "navigation partial renders signed-in help in the desktop nav and user menu" do
    help_menu_item = {
      key: :help_menu,
      label: "app.help",
      type: :partial,
      partial: "collavre/shared/navigation/help_button"
    }
    Navigation::Registry.instance.register(
      key: :help,
      label: "app.help",
      type: :partial,
      partial: "collavre/shared/navigation/help_button",
      priority: 170
    )
    Navigation::Registry.instance.register(
      key: :user_menu,
      label: "User",
      section: :user,
      type: :raw,
      button_content: "User",
      requires_user: true,
      children: [ help_menu_item ]
    )
    Current.user = users(:one)

    SystemSetting.stub(:help_menu_link, "") do
      render partial: "collavre/shared/navigation"
    end

    assert_select "a#creative-guide-link[href='/features?locale=en']", count: 2
    assert_select "a#creative-guide-link[target]", count: 0
  ensure
    Current.user = nil
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
