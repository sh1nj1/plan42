require_relative "../application_system_test_case"

class WorkspaceTreeDragDropSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "workspace-drag-user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Workspace Drag User",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true,
    )
    @left_root = Creative.create!(description: "Left root", user: @user, sequence: 0)
    @left_child = Creative.create!(description: "Left child", user: @user, parent: @left_root)
    @right_root = Creative.create!(description: "Right root", user: @user, sequence: 1)
    @right_child = Creative.create!(description: "Right child", user: @user, parent: @right_root)

    resize_window_to(1440, 900)
    sign_in_via_ui(@user)
  end

  test "user can drag from the workspace tree into the creative tree" do
    visit collavre.creatives_path(id: @right_root.id)
    assert_workspace_and_center_rows(@left_root, @right_child)

    html5_drag_by_offset(
      find("#workspace-creative-#{@left_root.id}"),
      find("#creative-#{@right_child.id}"),
      0,
      60,
    )

    assert_selector "#workspace-creative-#{@left_root.id}[data-parent-id='#{@right_root.id}']", wait: 10
    assert_equal @right_root, @left_root.reload.parent
  end

  test "user can drag from the creative tree into the workspace tree" do
    visit collavre.creatives_path(id: @left_root.id)
    assert_workspace_and_center_rows(@right_root, @left_child)

    # The workspace rows are compact, so the child band is only a few pixels
    # tall — aim at the exact centre rather than an offset from it.
    html5_drag_by_offset(
      find("#creative-#{@left_child.id}"),
      find("#workspace-creative-#{@right_root.id}"),
      0,
      0,
    )

    assert_selector "#workspace-creative-#{@left_child.id}[data-parent-id='#{@right_root.id}']", wait: 10
    assert_equal @right_root, @left_child.reload.parent
  end

  test "user can drag between workspace tree rows" do
    visit collavre.creatives_path(id: @left_root.id)
    assert_workspace_and_center_rows(@right_root, @left_child)

    html5_drag_by_offset(
      find("#workspace-creative-#{@left_root.id}"),
      find("#workspace-creative-#{@right_root.id}"),
      0,
      0,
    )

    assert_selector "#workspace-creative-#{@left_root.id}[data-parent-id='#{@right_root.id}']", wait: 10
    assert_equal @right_root, @left_root.reload.parent
  end

  test "visible descendant drops are rejected before any network write" do
    descendant = Creative.create!(description: "Visible descendant", user: @user, parent: @left_child)
    Creative.create!(description: "Descendant leaf", user: @user, parent: descendant)
    visit collavre.creatives_path(id: @left_root.id)
    expand_workspace_branch(@left_root)
    expand_workspace_branch(@left_child)
    assert_workspace_and_center_rows(descendant, @left_child)
    track_workspace_writes

    drag_between_workspace_rows(@left_child, descendant)

    assert_equal 0, page.evaluate_script("window.workspaceDndWriteRequests")
    assert_workspace_placement(@left_child, @left_root)
    assert_workspace_placement(descendant, @left_child)
    assert_selector "creative-tree-row[creative-id='#{@left_child.id}'][parent-id='#{@left_root.id}']"
    assert_equal @left_root.id, @left_child.reload.parent_id
    assert_equal @left_child.id, descendant.reload.parent_id
  end

  test "a forbidden workspace drop preserves placement in both trees and the database" do
    Creative.create!(description: "Source leaf", user: @user, parent: @left_child)
    visit collavre.creatives_path(id: @left_root.id)
    expand_workspace_branch(@left_root)
    assert_workspace_and_center_rows(@right_root, @left_child)
    before = Creative.where(user: @user).order(:id).pluck(:id, :parent_id, :sequence)
    track_workspace_writes(reject: true)

    drag_between_workspace_rows(@left_child, @right_root)

    assert_selector "body[data-workspace-dnd-rejected='true']"
    assert_equal 1, page.evaluate_script("window.workspaceDndWriteRequests")
    assert_workspace_placement(@left_child, @left_root)
    assert_selector "creative-tree-row[creative-id='#{@left_child.id}'][parent-id='#{@left_root.id}']"
    assert_equal before, Creative.where(user: @user).order(:id).pluck(:id, :parent_id, :sequence)
  end

  test "both trees share themed drop indicators without changing row geometry" do
    visit collavre.creatives_path(id: @left_root.id)
    assert_workspace_and_center_rows(@right_root, @left_child)

    results = page.evaluate_script(<<~JS, @left_root.id, @right_root.id, @left_child.id)
      ((sourceId, leftId, rightId) => {
        const source = document.getElementById(`workspace-creative-${sourceId}`);
        const targets = [document.getElementById(`workspace-creative-${leftId}`),
                         document.getElementById(`creative-${rightId}`)];
        const transfer = new DataTransfer();
        const dispatch = (el, type, y = 0, shiftKey = false) => el.dispatchEvent(
          new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: transfer,
                               clientX: 100, clientY: y, shiftKey }));
        const originalClass = document.body.className;
        const results = [];
        for (const theme of ['light', 'dark', 'custom']) {
          document.body.classList.toggle('dark-mode', theme === 'dark');
          document.body.classList.toggle('light-mode', theme !== 'dark');
          if (theme === 'custom') document.body.style.setProperty('--color-active', 'rgb(170, 60, 180)');
          for (const [direction, fraction] of [['top', 0.1], ['bottom', 0.9], ['child', 0.5]]) {
            const samples = targets.map(el => {
              const before = el.getBoundingClientRect();
              dispatch(source, 'dragstart');
              dispatch(el, 'dragover', before.top + before.height * fraction, true);
              const style = getComputedStyle(el);
              const icon = getComputedStyle(el, '::after');
              const after = el.getBoundingClientRect();
              const result = {
                marked: el.classList.contains(`drag-over-${direction}`),
                geometry: before.height === after.height && before.width === after.width,
                shadow: style.boxShadow, background: style.backgroundColor,
                radius: style.borderRadius, borderTop: style.borderTopWidth,
                borderBottom: style.borderBottomWidth,
                icon: direction === 'child' ? [icon.content, icon.color, icon.fontSize, icon.right] : null,
                badge: getComputedStyle(document.querySelector('.creative-link-drop-indicator')).display
              };
              dispatch(el, 'dragleave');
              dispatch(source, 'dragend');
              return result;
            });
            results.push({ theme, direction, samples });
          }
        }
        document.body.className = originalClass;
        document.body.style.removeProperty('--color-active');
        return results;
      })(...arguments)
    JS

    results.each do |result|
      left, right = result.fetch("samples")
      assert_equal left, right, "D&D styles differ: #{result}"
      assert left.fetch("marked"), "Wrong drop direction: #{result}"
      assert left.fetch("geometry"), "D&D changed row geometry: #{result}"
      assert_equal "block", left.fetch("badge")
      assert_equal "0px", left.fetch("borderTop")
      assert_equal "0px", left.fetch("borderBottom")
      refute_equal "rgba(0, 0, 0, 0)", left.fetch("background")
      if result.fetch("direction") == "child"
        assert_includes left.fetch("icon").first, "↳"
      else
        assert_includes left.fetch("shadow"), "2px"
      end
    end
    custom = results.find { |result| result["theme"] == "custom" && result["direction"] == "child" }
    assert_equal "rgb(170, 60, 180)", custom.fetch("samples").first.fetch("icon")[1]
  end

  test "individually linked creative stylesheet preserves drag feedback without token assets" do
    visit collavre.creatives_path(id: @left_root.id)
    assert_workspace_and_center_rows(@right_root, @left_child)

    styles = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const href = [...document.querySelectorAll('link[rel="stylesheet"]')]
        .find(link => link.href.includes('/collavre/creatives')).href;
      const frame = document.createElement('iframe');
      frame.onload = () => {
        const doc = frame.contentDocument;
        const style = (selector, pseudo) => frame.contentWindow.getComputedStyle(doc.querySelector(selector), pseudo);
        done({
          top: style('.drag-over-top').boxShadow,
          bottom: style('.drag-over-bottom').boxShadow,
          background: style('.drag-over-child').backgroundColor,
          arrow: style('.drag-over-child', '::after').content,
          arrowInset: style('.drag-over-child', '::after').right,
          opacity: style('.is-dragging').opacity,
          badgeBackground: style('.creative-link-drop-indicator').backgroundColor,
          badgePosition: style('.creative-link-drop-indicator').position,
          badgeLayer: style('.creative-link-drop-indicator').zIndex
        });
        frame.remove();
      };
      frame.srcdoc = `<link rel="stylesheet" href="${href}">
        <div class="creative-tree drag-over-top">Top</div>
        <div class="creative-tree drag-over-bottom">Bottom</div>
        <div class="creative-tree drag-over-child">Child</div>
        <div class="creative-tree is-dragging">Source</div>
        <div class="creative-link-drop-indicator">--&gt;</div>`;
      document.body.appendChild(frame);
    JS

    assert_includes styles.fetch("top"), "2px"
    assert_includes styles.fetch("bottom"), "-2px"
    refute_equal "rgba(0, 0, 0, 0)", styles.fetch("background")
    assert_includes styles.fetch("arrow"), "↳"
    assert_equal "8px", styles.fetch("arrowInset")
    assert_equal "0.55", styles.fetch("opacity")
    assert_equal "rgb(255, 255, 255)", styles.fetch("badgeBackground")
    assert_equal "fixed", styles.fetch("badgePosition")
    assert_equal "9999", styles.fetch("badgeLayer")
  end

  private

  def assert_workspace_and_center_rows(workspace_creative, center_creative)
    assert_selector "#workspace-creative-#{workspace_creative.id}", wait: 10
    assert_selector "#creative-#{center_creative.id}", wait: 10
  end

  def assert_workspace_placement(creative, parent)
    assert_selector ".creative-workspace-tree-item[data-creative-id='#{creative.id}'][data-parent-id='#{parent.id}']"
  end

  def expand_workspace_branch(creative)
    selector = "#workspace-creative-#{creative.id} > .creative-workspace-tree-branch-toggle"
    assert_selector selector
    toggle = find(selector)
    toggle.click if toggle["aria-expanded"] == "false"
  end

  # Await the delayed events, and enter at the same center point as the drop so
  # hysteresis cannot change a requested child drop into a sibling drop.
  def drag_between_workspace_rows(source, target)
    script = Html5DndHelpers::HTML5_DRAG_DROP_SCRIPT.sub(
      "var entryPoint = pointOnRect(sourceCenter, targetRect)",
      "var entryPoint = rectCenter(targetRect); entryPoint.x += x_offset; entryPoint.y += y_offset;"
    )
    html5_drag_async(
      find("#workspace-creative-#{source.id}"),
      find("#workspace-creative-#{target.id}"),
      0,
      0,
      step_delay: 150,
      script: script,
    )
  end

  def track_workspace_writes(reject: false)
    page.execute_script(<<~JS, reject)
      const reject = arguments[0];
      const originalFetch = window.fetch.bind(window);
      window.workspaceDndWriteRequests = 0;
      window.fetch = function(input, options = {}) {
        const url = new URL(typeof input === 'string' ? input : input.url, location.href);
        if (!['/creatives/reorder', '/creatives/link_drop'].includes(url.pathname)) return originalFetch(input, options);
        const method = (options.method || input.method || 'GET').toUpperCase();
        if (['GET', 'HEAD', 'OPTIONS'].includes(method)) return originalFetch(input, options);
        window.workspaceDndWriteRequests += 1;
        if (!reject || url.pathname !== '/creatives/reorder') return originalFetch(input, options);
        const response = new Response(JSON.stringify({ error: 'Forbidden' }), {
          status: 403, headers: { 'Content-Type': 'application/json' }
        });
        setTimeout(() => { document.body.dataset.workspaceDndRejected = 'true'; }, 0);
        return Promise.resolve(response);
      };
    JS
  end
end
