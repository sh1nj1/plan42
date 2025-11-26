require "application_system_test_case"

class DragDropSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "drag-user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "DragUser",
      email_verified_at: Time.current,
      notifications_enabled: false,
    )
    @root = Creative.create!(description: "Root", user: @user)
    @child_a = Creative.create!(description: "Task A", user: @user, parent: @root, sequence: 0)
    @child_b = Creative.create!(description: "Task B", user: @user, parent: @root, sequence: 1)

    resize_window_to
    sign_in_via_ui(@user)
  end

  test "user can reorder creatives with drag and drop" do
    visit creative_path(@root)

    assert_selector "#creative-#{@child_a.id}", wait: 5
    assert_selector "#creative-#{@child_b.id}", wait: 5

    source = find("#creative-#{@child_a.id}")
    target = find("#creative-#{@child_b.id}")

    drag_and_drop_with_offset(source, target, 0, 60)

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: "Task B", wait: 5
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: "Task A", wait: 5

    order = @root.reload.children.order(:sequence).map { |c| ActionController::Base.helpers.strip_tags(c.description) }
    assert_equal [ "Task B", "Task A" ], order
  end
end
