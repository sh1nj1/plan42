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

  private

  def assert_workspace_and_center_rows(workspace_creative, center_creative)
    assert_selector "#workspace-creative-#{workspace_creative.id}", wait: 10
    assert_selector "#creative-#{center_creative.id}", wait: 10
  end
end
