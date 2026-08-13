require_relative "../application_system_test_case"

# Below 1280px the workspace tree gives up its own grid column and becomes an
# off-canvas drawer behind a toggle handle. That used to apply only to the
# two-panel band (768-1279px); at one-panel widths the tree was `display: none`,
# so mobile users had no way to reach it at all. Both bands now share the same
# drawer rules — these lock that in at a mobile width and at the two-panel width
# that already worked.
class WorkspaceTreeDrawerTest < ApplicationSystemTestCase
  MOBILE_WIDTH = 430
  TWO_PANEL_WIDTH = 1000
  THREE_PANEL_WIDTH = 1400

  setup do
    @user = User.create!(
      email: "tree-drawer@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Tree Drawer",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true
    )
    # The tree only renders branch nodes, so "Root child" needs its own child to
    # show up under "Root creative" when the branch is expanded.
    @creative = Creative.create!(description: "Root creative", user: @user)
    @child = Creative.create!(description: "Root child", user: @user, parent: @creative)
    Creative.create!(description: "Leaf", user: @user, parent: @child)

    resize_window_to
    sign_in_via_ui(@user)
  end

  [ MOBILE_WIDTH, TWO_PANEL_WIDTH ].each do |width|
    test "the tree collapses to a reachable drawer at #{width}px" do
      visit_workspace(width)

      # Closed: slid off-canvas and hidden from the tab order, but still mounted.
      assert_selector ".creative-workspace-tree-region", visible: :all
      assert_no_selector ".creative-workspace-tree-link", text: "Root creative"
      assert_equal "fixed", computed_style(".creative-workspace-tree-region", "position")

      toggle = find(".creative-workspace-tree-toggle")
      assert toggle.visible?, "the drawer toggle is not reachable at #{width}px"
      assert_toggle_within_viewport

      toggle.click

      assert_selector ".creative-workspace-tree-region.is-open"
      assert_selector ".creative-workspace-tree-link", text: "Root creative", wait: 10
      assert_toggle_within_viewport "the toggle must stay on screen while open so the drawer can be closed"
    end

    test "the drawer keeps its expansion state across close and reopen at #{width}px" do
      visit_workspace(width)
      find(".creative-workspace-tree-toggle").click
      assert_selector ".creative-workspace-tree-region.is-open"
      assert_selector ".creative-workspace-tree-link", text: "Root creative", wait: 10

      find(".creative-workspace-tree-branch-toggle").click
      assert_selector ".creative-workspace-tree-link", text: "Root child", wait: 10

      find(".creative-workspace-tree-toggle").click
      assert_no_selector ".creative-workspace-tree-region.is-open"
      assert_selector ".creative-workspace-tree-toggle[aria-expanded='false']"
      find(".creative-workspace-tree-toggle").click

      assert_selector ".creative-workspace-tree-region.is-open"
      assert_selector ".creative-workspace-tree-link", text: "Root child", wait: 10
    end
  end

  test "the opened tree stays above the floating chat at mobile width" do
    visit_workspace(MOBILE_WIDTH)
    find(".creative-workspace-tree-toggle").click
    assert_selector ".creative-workspace-tree-region.is-open"

    # The docked chat is normally closed below 768px. Show it at its mobile
    # position to exercise the exact overlap that previously hid the drawer.
    page.execute_script(<<~JS)
      var popup = document.querySelector('#comments-popup');
      popup.style.display = 'flex';
      popup.classList.add('open');
    JS

    assert_tree_covers_floating_chat
  end

  # The handle is a fixed overlay. In the two-panel band it lands in the gutter
  # main leaves itself, but one-panel main runs flush to the left edge, so the
  # same offset would sit on top of the breadcrumb row and eat taps meant for it.
  [ MOBILE_WIDTH, TWO_PANEL_WIDTH ].each do |width|
    test "the closed drawer handle covers no control in the content column at #{width}px" do
      visit_workspace(width)
      assert_selector ".creative-workspace-tree-toggle"

      covered = page.evaluate_script(<<~JS)
        (function () {
          var handle = document.querySelector('.creative-workspace-tree-toggle').getBoundingClientRect();
          var controls = document.querySelectorAll('main a, main button, main input, main [role="button"]');
          return Array.prototype.filter.call(controls, function (control) {
            var rect = control.getBoundingClientRect();
            if (rect.width === 0 || rect.height === 0) return false;
            return rect.left < handle.right && rect.right > handle.left &&
                   rect.top < handle.bottom && rect.bottom > handle.top;
          }).map(function (control) {
            return (control.textContent || control.getAttribute('aria-label') || control.tagName).trim();
          });
        })();
      JS

      assert_empty covered, "the drawer handle overlaps content controls: #{covered.inspect}"
    end
  end

  test "the tree keeps its own column and hides the toggle at three-panel width" do
    visit_workspace(THREE_PANEL_WIDTH)

    assert_selector ".creative-workspace-tree-link", text: "Root creative", wait: 10
    assert_equal "static", computed_style(".creative-workspace-tree-region", "position")
    assert_equal "none", computed_style(".creative-workspace-tree-toggle", "display")
  end

  test "the mobile drawer tree contains vertical overscroll" do
    visit_workspace(MOBILE_WIDTH)

    find(".creative-workspace-tree-toggle").click

    assert_equal "contain", computed_style(".creative-workspace-tree-nav", "overscroll-behavior-y")
  end

  private

  def visit_workspace(width)
    resize_window_to(width, 800)
    visit collavre.creatives_path
    assert_selector ".creative-workspace-shell"
  end

  def computed_style(selector, property)
    page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector(#{selector.to_json})).getPropertyValue(#{property.to_json});
    JS
  end

  # `visible?` only proves the element is painted, not that a tap would land on
  # it — a drawer handle parked past the edge of a narrow viewport is dead. Hit
  # testing its centre point is the assertion that actually means "tappable".
  def assert_toggle_within_viewport(message = nil)
    hit = page.evaluate_script(<<~JS)
      (function () {
        var toggle = document.querySelector('.creative-workspace-tree-toggle');
        var rect = toggle.getBoundingClientRect();
        var x = rect.left + rect.width / 2;
        var y = rect.top + rect.height / 2;
        if (x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight) return false;
        return toggle.contains(document.elementFromPoint(x, y));
      })();
    JS

    assert hit, message || "the drawer toggle is not tappable — its centre is off screen or covered"
  end

  def assert_tree_covers_floating_chat
    covered_by_tree = page.evaluate_script(<<~JS)
      (function () {
	var tree = document.querySelector('.creative-workspace-tree-region');
	var popup = document.querySelector('#comments-popup');
	var treeRect = tree.getBoundingClientRect();
	var popupRect = popup.getBoundingClientRect();
	var left = Math.max(treeRect.left, popupRect.left);
	var right = Math.min(treeRect.right, popupRect.right);
	var top = Math.max(treeRect.top, popupRect.top);
	var bottom = Math.min(treeRect.bottom, popupRect.bottom);
	if (right <= left || bottom <= top) return false;

	var target = document.elementFromPoint((left + right) / 2, (top + bottom) / 2);
	return tree.contains(target);
      })();
    JS

    assert covered_by_tree, "the floating chat covers the opened workspace tree"
  end
end
