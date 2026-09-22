require_relative "../application_system_test_case"
require Rails.root.join("test/support/legacy_root_preferences")

class CreativeExpansionActionsTest < ApplicationSystemTestCase
  include LegacyRootPreferences
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

  test "preserves expand all state after navigation" do
    find("#expand-all-btn").click
    assert_selector row_selector(@child)

    wait_for_network_idle(timeout: 10)
    visit root_path
    visit collavre.creatives_path

    assert_selector row_selector(@child)
  end

  test "root expansion restores nested branches and initializes the workspace tree" do
    @user.update!(creative_workspace_enabled: true)
    grandchild = Creative.create!(description: "Grandchild", user: @user, parent: @child)
    visit collavre.creatives_path
    find("#expand-all-btn").click
    assert_selector row_selector(grandchild)
    wait_for_network_idle(timeout: 10)

    page.refresh
    assert_selector row_selector(grandchild)
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{grandchild.id}']", visible: :all

    # The first click starts expand-all mode; the next collapses every branch.
    find("#expand-all-btn").click
    find("#expand-all-btn").click
    refute_selector row_selector(@child)
    wait_for_network_idle(timeout: 10)
    page.refresh
    refute_selector row_selector(@child)
    refute_selector ".creative-workspace-tree-link[data-creative-id='#{@child.id}']", visible: :all
  end

  test "workspace restores branches split across duplicate root preferences" do
    allow_legacy_root_duplicates!
    @user.update!(creative_workspace_enabled: true)
    grandchild = Creative.create!(description: "Grandchild", user: @user, parent: @child)
    Collavre::UserCreativePreference.create!(user: @user, expanded_status: { @root_creative.id.to_s => true })
    Collavre::UserCreativePreference.create!(user: @user, expanded_status: { @child.id.to_s => true })

    page.refresh

    assert_selector ".creative-workspace-tree-link[data-creative-id='#{grandchild.id}']", visible: :all
    assert_equal 2, Collavre::UserCreativePreference.where(user: @user, creative_id: nil).count
  end

  test "clears expanded state after toggling twice" do
    find(row_selector(@root_creative)).hover
    find("#{row_selector(@root_creative)} .creative-toggle-btn").click
    assert_selector row_selector(@child), visible: :visible
    page.document.synchronize(5, errors: [ Minitest::Assertion ]) do
      assert UserCreativePreference.exists?(user: @user, creative_id: nil)
    end

    find(row_selector(@root_creative)).hover
    find("#{row_selector(@root_creative)} .creative-toggle-btn").click
    refute_selector row_selector(@child), visible: :visible

    # fetch-based queued saves are not tracked by wait_for_network_idle's XHR hook.
    page.document.synchronize(5, errors: [ Minitest::Assertion ]) do
      assert_nil UserCreativePreference.find_by(user: @user, creative_id: nil)
    end
    assert_not_empty @user.reload.expansion_save_sequences
  end

  test "visiting a comment share link opens popup and highlights comment" do
    comment = Comment.create!(creative: @child, user: @user, content: "Shared comment")

    visit collavre.creative_comment_path(@child, comment)

    assert_selector "#comments-popup", visible: :visible, wait: 10
    # Verify comment content loaded (not stuck on Loading...)
    assert_text "Shared comment", wait: 10
    assert_selector "#comment_#{comment.id}[data-highlighted='true']", wait: 10
  end
end
