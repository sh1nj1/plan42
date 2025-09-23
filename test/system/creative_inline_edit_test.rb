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

  test "shows saved row when starting another addition" do
    find("#creative-#{@root_creative.id}").hover
    find("#creative-#{@root_creative.id} .edit-inline-btn").click
    find("#inline-add-child").click

    refute_selector "#creative-children-#{@root_creative.id} .creative-row"

    find('trix-editor[input="inline-creative-description"]').click.set("First child")
    find("#inline-add").click

    assert_selector "#creative-children-#{@root_creative.id} .creative-row", text: "First child", count: 1

    find('trix-editor[input="inline-creative-description"]').click.set("Second child")
    find("#inline-close").click

    find("#creative-#{@root_creative.id}").hover
    find("#creative-#{@root_creative.id} .creative-toggle-btn").click

    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row", count: 2
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) > .creative-tree .creative-row", text: "First child"
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(2) > .creative-tree .creative-row", text: "Second child"

    new_creative_id = find("#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) > .creative-tree")["data-id"]
    new_creative = Creative.find(new_creative_id)
    assert_equal "First child", new_creative.description.body.to_plain_text
  end

  test "supports keyboard shortcuts for add and close" do
    find("#creative-#{@root_creative.id}").hover
    find("#creative-#{@root_creative.id} .edit-inline-btn").click
    find("trix-editor").send_keys([ :alt, :enter ])

    find('trix-editor[input="inline-creative-description"]').click.set("First child")
    find("trix-editor").send_keys([ :shift, :enter ])

    find('trix-editor[input="inline-creative-description"]').click.set("Second child")
    find("trix-editor").send_keys(:escape)

    find("#creative-#{@root_creative.id}").hover
    find("#creative-#{@root_creative.id} .creative-toggle-btn").click

    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row", count: 2
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) .creative-row", text: "First child"
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(2) .creative-row", text: "Second child"
  end

  test "maintains order when adding multiple creatives after the last node" do
    child_a = Creative.create!(description: "A", user: @user, parent: @root_creative)
    child_b = Creative.create!(description: "B", user: @user, parent: @root_creative)

    visit creative_path(@root_creative)

    find("#creative-#{child_b.id}").hover
    find("#creative-#{child_b.id} .edit-inline-btn").click
    find("#inline-add").click
    find('trix-editor[input="inline-creative-description"]').click.set("C")
    find("#inline-add").click
    find('trix-editor[input="inline-creative-description"]').click.set("D")
    find("#inline-close").click

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: child_a.description.to_plain_text
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: child_b.description.to_plain_text
    assert_selector "#creatives > creative-tree-row:nth-of-type(3) .creative-row", text: "C"
    assert_selector "#creatives > creative-tree-row:nth-of-type(4) .creative-row", text: "D"
  end

  test "adds as sibling when current node is collapsed" do
    child = Creative.create!(description: "Child", user: @user, parent: @root_creative)
    Creative.create!(description: "Grandchild", user: @user, parent: child)

    visit creative_path(@root_creative)

    find("#creative-#{child.id}").hover
    find("#creative-#{child.id} .edit-inline-btn").click
    find("#inline-add").click
    find('trix-editor[input="inline-creative-description"]').click.set("Sibling")
    find("#inline-close").click

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: "Child"
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: "Sibling"
  end

  test "shows editor at top and saves as first child when parent context exists" do
    existing_child = Creative.create!(description: "Existing", user: @user, parent: @root_creative)

    visit creative_path(@root_creative)

    find(".creative-actions-row .add-creative-btn").click
    find('trix-editor[input="inline-creative-description"]').click.set("New child")
    find("#inline-close").click

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: "New child"
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: existing_child.description.to_plain_text
  end
end
