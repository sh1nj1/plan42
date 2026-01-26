require_relative "../application_system_test_case"

class CreativeExpansionActionsTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @root_creative = Creative.create!(description: "Root", user: @user)
    @child = Creative.create!(description: "Child", user: @user, parent: @root_creative)

    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creatives_path
  end

  def row_selector(creative)
    "creative-tree-row[dom-id='creative-#{creative.id}']"
  end

  test "binds edit and comment buttons for loaded children" do
    find(row_selector(@root_creative)).hover
    find("#{row_selector(@root_creative)} .creative-toggle-btn").click

    child_selector = row_selector(@child)
    find("#{child_selector} .creative-row", visible: :visible).hover

    within(:css, child_selector) do
      assert_selector ".edit-inline-btn", visible: :visible
      find(".edit-inline-btn").click
    end

    assert_selector "#inline-edit-form-element", visible: :visible
    find("#inline-close").click
    wait_for_network_idle(timeout: 10)

    find("#{child_selector} .creative-row", visible: :visible).hover
    within(:css, child_selector) do
      find("[name='show-comments-btn']").click
    end

    assert_selector "#comments-popup", visible: :visible
  end

  test "binds edit and comment buttons after using expand all" do
    find("#expand-all-btn").click

    child_selector = row_selector(@child)
    find("#{child_selector} .creative-row", visible: :visible).hover

    within(:css, child_selector) do
      find("[name='show-comments-btn']").click
    end
    assert_selector "#comments-popup", visible: :visible

    assert_selector "#{row_selector(@child)} .edit-inline-btn"
    within(:css, child_selector) do
      find(".edit-inline-btn").click
    end

    assert_selector "#inline-edit-form-element", visible: :visible
    find("#inline-close").click
  end

  test "resets expand all state after navigation" do
    find("#expand-all-btn").click
    assert_selector row_selector(@child)

    visit root_path
    visit collavre.creatives_path

    refute_selector row_selector(@child)
  end

  test "clears expanded state after toggling twice" do
    find(row_selector(@root_creative)).hover
    find("#{row_selector(@root_creative)} .creative-toggle-btn").click
    find(row_selector(@root_creative)).hover
    find("#{row_selector(@root_creative)} .creative-toggle-btn").click

    assert_nil CreativeExpandedState.find_by(user: @user, creative: @root_creative)
  end

  test "visiting a comment share link opens popup and highlights comment" do
    comment = Comment.create!(creative: @child, user: @user, content: "Shared comment")

    visit collavre.creative_comment_path(@child, comment)

    assert_selector "#comments-popup", visible: :visible
    assert_selector "#comment_#{comment.id}.highlight-flash", wait: 5
  end
end
