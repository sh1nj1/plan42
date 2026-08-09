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
    Creative.create!(description: "Root creative", user: @user)

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
end
