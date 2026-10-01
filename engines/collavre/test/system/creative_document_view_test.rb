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
    assert_includes page.current_url, "view=document"
    assert_equal order, row_order

    find("#document-view-btn").click

    assert_no_selector ".creative-document-view"
    assert_selector "#creatives .creative-tree[draggable='true']", count: 2
    assert_not_includes page.current_url, "view=document"
    assert_equal order, row_order
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

  test "the open link enters the creative" do
    visit collavre.creative_path(@root, view: "document")

    find(content_selector(@first)).hover
    find("creative-tree-row[creative-id='#{@first.id}'] .creative-document-open").click

    assert_selector "creative-tree-row[is-title][creative-id='#{@first.id}']"
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

    assert_no_selector "#inline-edit-form-element", visible: true
    assert_equal url, page.current_url

    find(content_selector(line)).double_click
    assert_includes page.evaluate_script("window.getSelection().toString()"), "only"
  end
end
