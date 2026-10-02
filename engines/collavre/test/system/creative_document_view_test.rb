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

  test "a click edits in place and the change shows in the tree view" do
    visit collavre.creative_path(@root, view: "document")

    find(content_selector(@first)).click

    field = find(".lexical-content-editable", wait: 5)
    find("[data-lexical-editor-root][data-editor-ready='true']", wait: 5)
    field.send_keys(:end, " edited")
    find("#inline-close", wait: 5).click
    assert_no_selector ".lexical-content-editable", visible: true, wait: 10

    assert_selector content_selector(@first), text: "First paragraph edited"
    find("#document-view-btn").click
    assert_selector content_selector(@first), text: "First paragraph edited"
    assert_equal "First paragraph edited", ActionController::Base.helpers.strip_tags(@first.reload.description).strip
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
