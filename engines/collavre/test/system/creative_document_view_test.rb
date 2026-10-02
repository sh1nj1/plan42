require_relative "../application_system_test_case"

class CreativeDocumentViewTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "doc-view@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Doc Viewer",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @root = Creative.create!(description: "Spec", user: @user)
    @first = Creative.create!(description: "First paragraph", user: @user, parent: @root)
    @second = Creative.create!(description: "Second paragraph", user: @user, parent: @root)

    resize_window_to
    sign_in_via_ui(@user)
  end

  def content_selector(creative)
    "creative-tree-row[creative-id='#{creative.id}'] .creative-content"
  end

  # The refresh that follows a save re-renders the row some time after the
  # editor closed; this does the same render without the wait.
  def rerender_row(creative)
    page.evaluate_async_script(<<~JS, "creative-tree-row[creative-id='#{creative.id}']")
      const row = document.querySelector(arguments[0]);
      row.requestUpdate();
      row.updateComplete.then(arguments[1]);
    JS
  end

  def tree_selector(creative)
    "creative-tree-row[creative-id='#{creative.id}'] .creative-tree"
  end

  def row_order
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#creatives creative-tree-row')).map(row => row.getAttribute('creative-id'))
    JS
  end

  def drag_select(from, to)
    page.driver.browser.action
        .move_to(find(content_selector(from)).native, -40, 0)
        .click_and_hold
        .move_to(find(content_selector(to)).native, 40, 0)
        .release
        .perform
  end

  test "switching views keeps content and order, and the toggle returns to the tree" do
    visit collavre.creative_path(@root)
    assert_selector content_selector(@first)
    order = row_order

    find("#document-view-btn").click

    assert_selector ".creative-document-view #creatives[data-view-mode='document']"
    assert_selector "#document-view-btn[aria-pressed='true']"
    assert_no_selector "#creatives .creative-tree[draggable='true']"
    assert_equal order, row_order

    find("#document-view-btn").click

    assert_no_selector ".creative-document-view"
    assert_selector "#creatives .creative-tree[draggable='true']", count: 2
    assert_equal order, row_order
  end

  test "the document view stays on while moving through the tree and after a reload" do
    visit collavre.creative_path(@root)
    find("#document-view-btn").click
    assert_selector ".creative-document-view #creatives[data-view-mode='document']"

    visit collavre.creative_path(@first)
    assert_selector ".creative-document-view #document-view-btn[aria-pressed='true']"
    assert_not_includes page.current_url, "view="

    visit collavre.creatives_path
    assert_selector ".creative-document-view #creatives[data-view-mode='document']"

    page.go_back
    assert_selector ".creative-document-view #document-view-btn[aria-pressed='true']"

    find("#document-view-btn").click
    assert_no_selector ".creative-document-view"

    visit collavre.creative_path(@root)
    assert_selector "#document-view-btn[aria-pressed='false']"
    assert_no_selector ".creative-document-view"
  end

  test "a document view link opens the view and keeps it for later pages" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector ".creative-document-view #creatives[data-view-mode='document']"
    assert_not_includes page.current_url, "view="

    visit collavre.creative_path(@first)
    assert_selector ".creative-document-view #document-view-btn[aria-pressed='true']"
  end

  test "dragging across rows selects text without moving, entering or editing" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@second)
    order = row_order
    url = page.current_url

    drag_select(@first, @second)

    selected = page.evaluate_script("window.getSelection().toString()")
    assert_includes selected, "paragraph"
    assert_includes selected, "Second"
    assert_no_selector "#inline-edit-form-element", visible: true
    assert_equal url, page.current_url
    assert_equal order, row_order
  end

  test "the hover handle drags a row, and the edit button stays hidden" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@second)
    handle = "creative-tree-row[creative-id='#{@first.id}'] .creative-drag-handle"

    assert_no_selector "#creatives .edit-inline-btn", visible: true
    find(content_selector(@first)).hover
    assert_no_selector "#creatives .edit-inline-btn", visible: true

    drag_and_drop_with_offset(find(handle), find(tree_selector(@second)), 0, 60)

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-content", text: "Second paragraph"
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-content", text: "First paragraph"
    assert_equal [ @second.id, @first.id ], @root.reload.children.order(:sequence).pluck(:id)

    find("#document-view-btn").click
    assert_no_selector ".creative-drag-handle"
  end

  test "the title is no drop target and keeps touch dragging off" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@second)
    order = row_order
    ids = @root.children.order(:sequence).pluck(:id)

    assert_selector ".creative-tree-title[data-dnd-disabled]"
    find(content_selector(@second)).hover
    handle = "creative-tree-row[creative-id='#{@second.id}'] .creative-drag-handle"
    drag_and_drop_with_offset(find(handle), find(".creative-tree-title"), 0, 4)

    assert_no_selector ".drag-over"
    assert_equal order, row_order
    assert_equal ids, @root.reload.children.order(:sequence).pluck(:id)
    assert_equal @root.id, @second.reload.parent_id

    find("#document-view-btn").click
    assert_no_selector ".creative-tree-title[data-dnd-disabled]"
  end

  test "the document fills the width its container gives it" do
    resize_window_to(2600, 900)
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@first)

    widths = page.evaluate_script(<<~JS)
      [document.getElementById('creatives').getBoundingClientRect().width,
       document.getElementById('creatives').parentElement.getBoundingClientRect().width]
    JS
    assert_operator widths[0], :>, 760
    assert_in_delta widths[1], widths[0], 1
  end

  test "switching to the tree view while editing keeps the edited row locked" do
    visit collavre.creative_path(@root, view: "document")

    find(content_selector(@first)).click
    find("[data-lexical-editor-root][data-editor-ready='true']", wait: 5)
    find("#document-view-btn").click

    assert_selector "#{tree_selector(@second)}[draggable='true']"
    assert_selector "#{tree_selector(@first)}[draggable='false']"
    find("#inline-close", wait: 5).click
    assert_selector "#{tree_selector(@first)}[draggable='true']", wait: 10
  end

  test "closing the editor without a change leaves the row free in both views" do
    visit collavre.creative_path(@root, view: "document")

    find(content_selector(@first)).click
    find("[data-lexical-editor-root][data-editor-ready='true']", wait: 5)
    find("#inline-close", wait: 5).click
    assert_no_selector ".lexical-content-editable", visible: true, wait: 10

    # The hidden form stays in the row it last edited; a later render must not
    # read it as an open editor and lock the row.
    assert_selector "#{tree_selector(@first)} > #inline-edit-form", visible: :hidden
    rerender_row(@first)
    assert_no_selector "#{tree_selector(@first)}[draggable]"

    find("#document-view-btn").click
    assert_selector "#creatives .creative-tree[draggable='true']", count: 2
  end

  test "a click edits in place and the change shows in the tree view" do
    visit collavre.creative_path(@root, view: "document")

    find(content_selector(@first)).click

    field = find(".lexical-content-editable", wait: 5)
    find("[data-lexical-editor-root][data-editor-ready='true']", wait: 5)
    field.send_keys(:end, " edited")
    find("#inline-close", wait: 5).click
    assert_no_selector ".lexical-content-editable", visible: true, wait: 10

    assert_selector content_selector(@first), text: "First paragraph edited"
    # Closing the editor must not turn the row back into a drag source, and the
    # hidden form it leaves in the row must not keep the row locked either.
    rerender_row(@first)
    assert_no_selector "#{tree_selector(@first)}[draggable]"
    find("#document-view-btn").click
    assert_selector "#{tree_selector(@first)}[draggable='true']"
    assert_selector content_selector(@first), text: "First paragraph edited"
    assert_equal "First paragraph edited", ActionController::Base.helpers.strip_tags(@first.reload.description).strip
  end

  test "the keyboard reaches the hidden edit button and opens the editor" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@first)
    button = "creative-tree-row[creative-id='#{@first.id}'] .edit-inline-btn"

    page.execute_script("document.querySelector(arguments[0]).focus()", button)
    assert page.evaluate_script("document.activeElement.matches(arguments[0])", button)
    # The icon-only button needs a name for screen readers, on rows and the title.
    label = I18n.t("collavre.creatives.edit_title")
    assert_selector "#{button}[aria-label='#{label}']", visible: :all
    assert_selector "creative-tree-row[is-title] .edit-inline-btn[aria-label='#{label}']", visible: :all
    page.driver.browser.action.send_keys(:enter).perform

    assert_selector "#inline-edit-form-element", visible: true
  end

  test "a click on the title edits it in place" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@first)

    find(".creative-title-content").click

    field = find(".lexical-content-editable", wait: 5)
    find("[data-lexical-editor-root][data-editor-ready='true']", wait: 5)
    field.send_keys(:end, " edited")
    find("#inline-close", wait: 5).click
    assert_no_selector ".lexical-content-editable", visible: true, wait: 10

    assert_selector ".creative-title-content", text: "Spec edited"
    assert_equal "Spec edited", ActionController::Base.helpers.strip_tags(@root.reload.description).strip
  end

  test "select mode selects rows instead of opening the editor" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@first)
    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click

    find(content_selector(@first)).click
    find(content_selector(@second)).click

    assert_selector "#creatives .select-creative-checkbox:checked", count: 2
    assert_no_selector "#inline-edit-form-element", visible: true

    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click
    find(content_selector(@first)).click

    assert_selector ".lexical-content-editable", wait: 5
  end

  test "switching views in select mode keeps the checkboxes and the selection" do
    visit collavre.creative_path(@root)
    assert_selector content_selector(@first)
    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click
    find("creative-tree-row[creative-id='#{@first.id}'] .select-creative-checkbox").click

    find("#document-view-btn").click

    assert_selector "#creatives[data-view-mode='document'] .select-creative-checkbox", visible: true, count: 2
    assert_selector "#creatives .select-creative-checkbox:checked", visible: true, count: 1

    find("#document-view-btn").click

    assert_selector "#creatives .select-creative-checkbox", visible: true, count: 2
    assert_selector "#creatives .select-creative-checkbox:checked", visible: true, count: 1
  end

  test "progress and the way into a creative are left out, and return with the tree" do
    visit collavre.creative_path(@root, view: "document")
    assert_selector content_selector(@first)
    progress = ":is(#creatives, .creative-tree-title) :is(.progress-toggle-wrap, .creative-progress-complete, .creative-progress-incomplete)"

    assert_no_selector progress, visible: true
    assert_no_selector ".creative-document-open"
    assert_selector "creative-tree-row[creative-id='#{@first.id}'] .comments-btn", visible: :all

    find("#document-view-btn").click

    assert_selector progress, visible: true, count: 3
  end

  test "a reader can select but not edit" do
    owner = User.create!(
      email: "doc-owner@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Owner",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    shared = Creative.create!(description: "Shared spec", user: owner)
    line = Creative.create!(description: "Read only line", user: owner, parent: shared)
    CreativeShare.create!(creative: shared, user: @user, permission: :read)

    visit collavre.creative_path(shared, view: "document")
    url = page.current_url

    find(content_selector(line)).click
    find(".creative-title-content").click

    assert_no_selector "#creative-markdown-block[can-write]"
    assert_no_selector "#inline-edit-form-element", visible: true
    assert_equal url, page.current_url

    find(content_selector(line)).double_click
    assert_includes page.evaluate_script("window.getSelection().toString()"), "only"
  end
end
