require_relative "../application_system_test_case"

# The GNB "chat" button used to assign window.location.href, which is a full
# browser navigation: assets are re-downloaded and the workspace tree and
# docked chat are rebuilt. It now drives the #creative-workspace-content
# turbo-frame instead.
class CreativeFilterNavigationTest < ApplicationSystemTestCase
  COMMENT_BUTTON = ".progress-filter-btn[data-progress-filter-filter-param='comment']".freeze

  setup do
    @user = User.create!(
      email: "filter-nav@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Filter Nav",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true,
      system_admin: true
    )
    @creative = Creative.create!(description: "Root creative", user: @user)
    Creative.create!(description: "Root child", user: @user, parent: @creative)

    resize_window_to
    sign_in_via_ui(@user)
  end

  # Marks both the window and a node outside the workspace frame. A hard
  # navigation loses both; a full Turbo Drive visit keeps the window but
  # replaces the body, so only a frame-scoped visit keeps the DOM marker.
  def mark_page
    page.execute_script(<<~JS)
      window.__filterNavMarker = 'kept'
      document.querySelector('.creative-workspace-shell').dataset.filterNavMarker = 'kept'
    JS
  end

  test "chat filter replaces only the workspace frame" do
    visit collavre.creatives_path
    assert_selector "turbo-frame#creative-workspace-content"
    mark_page

    find(COMMENT_BUTTON).click

    assert_current_path(/comment=true/, url: false)
    assert_selector ".creative-workspace-shell[data-filter-nav-marker='kept']"
    assert_equal "kept", page.evaluate_script("window.__filterNavMarker")
  end

  test "chat filter keeps the workspace tree and docked chat mounted" do
    visit collavre.creatives_path
    assert_selector ".creative-workspace-shell"
    tree_present = page.has_selector?("#creative-workspace-content")
    assert tree_present

    mark_page
    find(COMMENT_BUTTON).click
    assert_current_path(/comment=true/, url: false)

    assert_selector ".creative-workspace-shell[data-filter-nav-marker='kept']"
  end

  test "chat filter button reflects the new state without a server round trip" do
    visit collavre.creatives_path
    assert_no_selector "#{COMMENT_BUTTON}.active"

    find(COMMENT_BUTTON).click

    assert_selector "#{COMMENT_BUTTON}.active"
  end

  test "chat filter toggles back off" do
    visit collavre.creatives_path
    find(COMMENT_BUTTON).click
    assert_selector "#{COMMENT_BUTTON}.active"
    assert_current_path(/comment=true/, url: false)

    find(COMMENT_BUTTON).click

    assert_no_selector "#{COMMENT_BUTTON}.active"
    assert_current_path(collavre.creatives_path)
  end

  test "chat filter pressed outside the creative index lands on the index" do
    visit collavre.users_path
    assert_no_selector "turbo-frame#creative-workspace-content"

    find(COMMENT_BUTTON).click

    assert_current_path(/\/creatives\?comment=true/, url: false)
    assert_selector "turbo-frame#creative-workspace-content"
  end

  # The pill's selected surface must live on the ::before overlay and cross-fade
  # with opacity. Animating `background` on the button itself re-rasterises its
  # rounded corners on every frame, which is what produced the folded-corner
  # artifact on mobile once the filter started toggling `.active` in place
  # instead of reloading the page.
  def computed(element, property, pseudo = nil)
    target = pseudo ? "'#{pseudo}'" : "null"
    page.evaluate_script(
      "getComputedStyle(arguments[0], #{target}).getPropertyValue('#{property}').trim()",
      element
    )
  end

  def assert_eventually_equal(expected, element, property, pseudo = nil)
    deadline = Time.current + Capybara.default_max_wait_time
    actual = computed(element, property, pseudo)
    while actual != expected && Time.current < deadline
      sleep 0.05
      actual = computed(element, property, pseudo)
    end
    assert_equal expected, actual
  end

  TRANSPARENT = "rgba(0, 0, 0, 0)".freeze

  test "chat filter draws its selected surface on an opacity overlay" do
    visit collavre.creatives_path
    button = find(COMMENT_BUTTON)

    assert_equal TRANSPARENT, computed(button, "background-color")
    assert_equal "0", computed(button, "opacity", "::before")
    assert_equal "opacity", computed(button, "transition-property", "::before")
    refute_includes computed(button, "transition-property"), "background"
    refute_equal TRANSPARENT, computed(button, "background-color", "::before")

    button.click
    assert_selector "#{COMMENT_BUTTON}.active"

    assert_eventually_equal "1", button, "opacity", "::before"
    assert_equal TRANSPARENT, computed(button, "background-color"),
                 "the active button must stay transparent so the overlay is the only surface"
  end

  test "search trigger draws its selected surface on an opacity overlay" do
    visit collavre.creatives_path
    trigger = find(".search-popup-trigger")

    assert_equal TRANSPARENT, computed(trigger, "background-color")
    assert_equal "0", computed(trigger, "opacity", "::before")
    assert_equal "opacity", computed(trigger, "transition-property", "::before")
    refute_includes computed(trigger, "transition-property"), "background"

    trigger.click
    fill_in "search", with: "Root"
    find("#search").send_keys(:enter)

    assert_selector ".search-popup-trigger.active"
    trigger = find(".search-popup-trigger")
    assert_eventually_equal "1", trigger, "opacity", "::before"
    assert_equal TRANSPARENT, computed(trigger, "background-color")
  end

  test "tree navigation clears persistent search controls with the filter URL" do
    visit collavre.creatives_path
    find(".search-popup-trigger").click
    fill_in "search", with: "Root"
    find("#search").send_keys(:enter)

    assert_current_path(/search=Root/, url: false)
    assert_selector ".search-popup-trigger.active"

    find(".creative-workspace-tree-toggle").click
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{@creative.id}']", wait: 10
    find(".creative-workspace-tree-link", text: "Root creative").click

    assert_current_path(collavre.creatives_path(id: @creative.id))
    assert_no_selector ".search-popup-trigger.active"
    assert_equal "", find("#search", visible: :all).value
  end
end
