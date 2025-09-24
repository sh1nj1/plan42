require "application_system_test_case"

class CreativeInlineEditTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @root_creative = Creative.create!(description: "Root", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
    visit creatives_path
  end

  def open_inline_editor(creative)
    find("#creative-#{creative.id}").hover
    find("#creative-#{creative.id} .edit-inline-btn", wait: 5).click
    assert_selector "#inline-edit-form-element", wait: 5
  end

  def inline_editor_field
    find('trix-editor[input="inline-creative-description"]', wait: 5)
  end

  def fill_inline_editor(text)
    inline_editor_field.click.set(text)
  end

  def add_inline_child(text)
    fill_inline_editor(text)
    find("#inline-add", wait: 5).click
  end

  def close_inline_editor
    find("#inline-close", wait: 5).click
    assert_no_selector "#inline-edit-form-element", wait: 5
  end

  def expand_creative(creative)
    find("#creative-#{creative.id}").hover
    find("#creative-#{creative.id} .creative-toggle-btn", wait: 5).click
  end

  test "shows saved row when starting another addition" do
    open_inline_editor(@root_creative)
    find("#inline-add-child", wait: 5).click

    assert_no_selector "#creative-children-#{@root_creative.id} .creative-row", wait: 1

    add_inline_child("First child")

    assert_selector "#creative-children-#{@root_creative.id} .creative-row", text: "First child", count: 1, wait: 5

    fill_inline_editor("Second child")
    close_inline_editor

    expand_creative(@root_creative)
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row", count: 2, wait: 5
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) > .creative-tree .creative-row", text: "First child"
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(2) > .creative-tree .creative-row", text: "Second child"

    first_row = find(
      "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) > .creative-tree",
      wait: 5
    )
    first_id = first_row["data-id"]
    assert_equal "First child", Creative.find(first_id).description.body.to_plain_text
  end

  test "supports keyboard shortcuts for add and close" do
    open_inline_editor(@root_creative)
    inline_editor_field.send_keys([ :alt, :enter ])

    fill_inline_editor("First child")
    inline_editor_field.send_keys([ :shift, :enter ])

    fill_inline_editor("Second child")
    inline_editor_field.send_keys(:escape)

    expand_creative(@root_creative)

    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row", count: 2, wait: 5
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) .creative-row", text: "First child"
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(2) .creative-row", text: "Second child"
  end

  test "maintains order when adding multiple creatives after the last node" do
    child_a = Creative.create!(description: "A", user: @user, parent: @root_creative)
    child_b = Creative.create!(description: "B", user: @user, parent: @root_creative)

    visit creative_path(@root_creative)

    open_inline_editor(child_b)
    find("#inline-add", wait: 5).click
    fill_inline_editor("C")
    find("#inline-add", wait: 5).click
    fill_inline_editor("D")
    close_inline_editor

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: child_a.description.to_plain_text, wait: 5
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: child_b.description.to_plain_text
    assert_selector "#creatives > creative-tree-row:nth-of-type(3) .creative-row", text: "C"
    assert_selector "#creatives > creative-tree-row:nth-of-type(4) .creative-row", text: "D"
  end

  test "adds as sibling when current node is collapsed" do
    child = Creative.create!(description: "Child", user: @user, parent: @root_creative)
    Creative.create!(description: "Grandchild", user: @user, parent: child)

    visit creative_path(@root_creative)

    open_inline_editor(child)
    find("#inline-add", wait: 5).click
    fill_inline_editor("Sibling")
    close_inline_editor

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: "Child", wait: 5
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: "Sibling"
  end

  test "shows editor at top and saves as first child when parent context exists" do
    existing_child = Creative.create!(description: "Existing", user: @user, parent: @root_creative)

    visit creative_path(@root_creative)

    find(".creative-actions-row .add-creative-btn").click
    fill_inline_editor("New child")
    close_inline_editor

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: "New child", wait: 5
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: existing_child.description.to_plain_text
  end
end
