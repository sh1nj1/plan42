require_relative "../application_system_test_case"

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
    visit collavre.creative_path(@root)

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

  # The drop is rendered in place, so the tree must not be refetched afterwards:
  # a refetch replaces every row, and a marker left on one would not survive it.
  test "reordering keeps the rendered rows instead of reloading the tree" do
    visit collavre.creative_path(@root)

    assert_selector "#creative-#{@child_a.id}", wait: 5
    assert_selector "#creative-#{@child_b.id}", wait: 5
    page.execute_script("document.querySelectorAll('#creatives creative-tree-row').forEach((row) => { row.dataset.keptAcrossDrop = 'true' })")

    drag_and_drop_with_offset(find("#creative-#{@child_a.id}"), find("#creative-#{@child_b.id}"), 0, 60)

    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: "Task A", wait: 5
    # Longer than the move request, the reload debounce and the refetch it would start.
    sleep 1
    assert_equal @child_b, @root.reload.children.order(:sequence).first

    assert_selector "#creatives creative-tree-row[data-kept-across-drop='true']", count: 2
  end

  # No refetch follows an in-place drop, and the user who dropped is left out of
  # the broadcast, so the progress the new parent rolls up has to arrive with it.
  test "nesting a row updates its new parent's progress without reloading the tree" do
    @child_a.update!(progress: 1.0)
    visit collavre.creative_path(@root)

    assert_selector "#creative-#{@child_a.id}", wait: 5
    assert_selector "#creative-#{@child_b.id}", wait: 5
    page.execute_script("document.querySelectorAll('#creatives creative-tree-row').forEach((row) => { row.dataset.keptAcrossDrop = 'true' })")

    drag_and_drop_with_offset(find("#creative-#{@child_a.id}"), find("#creative-#{@child_b.id}"), 0, 0)

    assert_selector "creative-tree-row[creative-id='#{@child_b.id}'][data-progress-value='1']", wait: 5
    assert_equal @child_b, @child_a.reload.parent
    assert_selector "#creatives creative-tree-row[data-kept-across-drop='true']", count: 2
  end
end
