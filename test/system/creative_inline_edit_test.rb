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
    wait_for_network_idle(timeout: 10)
    inline_editor_container.find(".lexical-content-editable", wait: 5)
  end

  def inline_editor_container
    wait_for_network_idle(timeout: 10)
    find("[data-lexical-editor-root][data-editor-ready='true']", wait: 5)
  end

  def fill_inline_editor(text)
    wait_for_network_idle(timeout: 10)
    attempts = 0

    begin
      field = inline_editor_field
      field.click
      inline_editor_field.set(text)
    rescue Selenium::WebDriver::Error::StaleElementReferenceError
      attempts += 1
      raise if attempts >= 3

      sleep 0.1
      retry
    end
    wait_for_network_idle(timeout: 10)
  end

  def add_inline_child(text)
    fill_inline_editor(text)
    find("#inline-add", wait: 5).click
  end

  def start_inline_child_form
    find("#inline-add", wait: 5).click
    find("#inline-level-down", wait: 5).click
  end

  def close_inline_editor
    find("#inline-close", wait: 5).click
    assert_no_selector ".lexical-content-editable", visible: true, wait: 5
    wait_for_network_idle(timeout: 10)
  end

  def expand_creative(creative)
    wait_for_network_idle(timeout: 10)
    find("#creative-#{creative.id}").hover
    # Force visibility for test stability as hover can be flaky
    execute_script("document.querySelector('#creative-#{creative.id} .creative-toggle-btn').style.visibility = 'visible'")
    find("#creative-#{creative.id} .creative-toggle-btn", wait: 5).click
  end

  def attach_inline_image(file_path)
    input = inline_editor_container.find(
      "input[type='file'][accept='image/*']",
      visible: false,
      wait: 5
    )
    input.attach_file(file_path)
    assert_selector "img", wait: 10
  end

  test "shows saved row when starting another addition" do
    open_inline_editor(@root_creative)
    start_inline_child_form

    assert_no_selector "#creative-children-#{@root_creative.id} .creative-row", wait: 1

    add_inline_child("First child")

    assert_selector "#creative-children-#{@root_creative.id} .creative-row", text: "First child", count: 1, wait: 5, visible: :all

    fill_inline_editor("Second child")
    close_inline_editor

    expand_creative(@root_creative)
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row", count: 2, wait: 5, visible: :all
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) > .creative-tree .creative-row", text: "First child", visible: :all
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(2) > .creative-tree .creative-row", text: "Second child", visible: :all

    @root_creative.reload
    first_child = @root_creative.children.order(:created_at).first
    assert_equal "First child", ActionController::Base.helpers.strip_tags(first_child.description)
  end

  test "supports keyboard shortcuts for add and close" do
    open_inline_editor(@root_creative)
    inline_editor_field.send_keys([ :alt, :enter ])
    sleep 0.5

    fill_inline_editor("First child")
    inline_editor_field.send_keys([ :shift, :enter ])
    sleep 0.5

    fill_inline_editor("Second child")
    inline_editor_field.send_keys(:escape)
    sleep 0.5

    expand_creative(@root_creative)

    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row", count: 2, wait: 5, visible: :all
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(1) .creative-row", text: "First child", visible: :all
    assert_selector "#creative-children-#{@root_creative.id} > creative-tree-row:nth-of-type(2) .creative-row", text: "Second child", visible: :all
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

    assert_selector "#creatives > creative-tree-row:nth-of-type(1) .creative-row", text: ActionController::Base.helpers.strip_tags(child_a.description), wait: 5
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: ActionController::Base.helpers.strip_tags(child_b.description)
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
    assert_selector "#creatives > creative-tree-row:nth-of-type(2) .creative-row", text: ActionController::Base.helpers.strip_tags(existing_child.description)
  end

  test "does not duplicate attachments when re-editing inline creative" do
    fixture_path = Rails.root.join("test/fixtures/files/small.png")

    open_inline_editor(@root_creative)

    fill_inline_editor("")

    attach_inline_image(fixture_path)

    close_inline_editor

    @root_creative.reload
    wait_for_network_idle(timeout: 10)

    assert_selector "#creative-#{@root_creative.id} .creative-content img",
                    count: 1,
                    wait: 5,
                    visible: :all
    assert_equal 1, @root_creative.description.scan(/<img/).length

    open_inline_editor(@root_creative)
    assert_selector ".lexical-content-editable img", count: 1, wait: 5
    close_inline_editor

    assert_selector "#creative-#{@root_creative.id} .creative-content img",
                    count: 1,
                    wait: 5,
                    visible: :all
  end

  test "disables inline actions when unavailable" do
    Creative.create!(description: "Second root", user: @user)

    visit creatives_path

    open_inline_editor(@root_creative)

    assert_selector "#inline-move-up[disabled]", wait: 5
    assert_selector "#inline-level-down[disabled]", wait: 5
    assert_selector "#inline-level-up[disabled]", wait: 5
    assert_no_selector "#inline-delete-toggle[disabled]", wait: 5
    assert_no_selector "#inline-move-down[disabled]", wait: 5

    find("#inline-move-down", wait: 5).click
    wait_for_network_idle(timeout: 10)

    assert_no_selector "#inline-move-up[disabled]", wait: 5
    assert_no_selector "#inline-level-down[disabled]", wait: 5

    find("#inline-level-down", wait: 5).click
    wait_for_network_idle(timeout: 10)

    assert_no_selector "#inline-level-up[disabled]", wait: 5

    find("#inline-add", wait: 5).click
    wait_for_network_idle(timeout: 10)

    assert_selector "#inline-delete-toggle[disabled]", wait: 5
  end
end
