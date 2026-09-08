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
    page.execute_async_script(
      script, find("#workspace-creative-#{source.id}").native,
      find("#workspace-creative-#{target.id}").native, 150, [], 0, 0
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
