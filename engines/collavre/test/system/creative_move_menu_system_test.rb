require_relative "../application_system_test_case"

class CreativeMoveMenuSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "creative-move-menu@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Move Menu User",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true
    )
    @source = Creative.create!(description: "Menu source", user: @user)
    @destination = Creative.create!(description: "Menu destination", user: @user)
    resize_window_to(1440, 900)
    sign_in_via_ui(@user)
    visit collavre.creatives_path
  end

  test "keyboard moves a creative using the shared destination picker" do
    visit collavre.creatives_path(id: @source.id)
    open_move_menu(:return)
    find('[data-creative-move-target="destination"]').send_keys(:return)
    input = find('[data-link-creative-target="input"]')
    input.set("Menu destination")
    assert_selector "#link-creative-modal .link-result-item[data-id='#{@destination.id}']"
    input.send_keys(:return)
    find('[data-creative-move-target="confirm"]').send_keys(:return)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "#workspace-creative-#{@source.id}[data-parent-id='#{@destination.id}']"
    assert_equal @destination, @source.reload.parent
  end

  test "workspace move menu offers a click-only path" do
    visit collavre.creatives_path(id: @source.id)
    open_move_menu
    find('[data-creative-move-target="destination"]').click
    find('[data-link-creative-target="input"]').set("Menu destination")
    find("#link-creative-modal .link-result-item[data-id='#{@destination.id}']").click
    find('[data-creative-move-target="confirm"]').click

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "#workspace-creative-#{@source.id}[data-parent-id='#{@destination.id}']"
    assert_equal @destination, @source.reload.parent
  end

  test "Escape cancels and returns focus without moving" do
    visit collavre.creatives_path(id: @source.id)
    open_move_menu(:return)
    find('[data-creative-move-target="destination"]').send_keys(:escape)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_equal "creative-overflow-menu", page.evaluate_script("document.activeElement.getAttribute('aria-controls')")
    assert_nil @source.reload.parent_id
  end

  test "keyboard creates a link from a readable source without the workspace" do
    @user.update!(creative_workspace_enabled: false)
    @source.update!(user: users(:two))
    CreativeShare.create!(creative: @source, user: @user, permission: :read)
    visit collavre.creatives_path(id: @source.id)

    open_move_menu(:return)
    assert_selector '[data-creative-move-target="mode"] option[value="move"][disabled]', visible: :all
    assert_equal "link", find('[data-creative-move-target="mode"]').value
    find('[data-creative-move-target="destination"]').send_keys(:return)
    input = find('[data-link-creative-target="input"]')
    input.set("Menu destination")
    assert_selector "#link-creative-modal .link-result-item[data-id='#{@destination.id}']"
    input.send_keys(:return)
    find('[data-creative-move-target="confirm"]').send_keys(:return)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert Creative.exists?(origin_id: @source.id, parent_id: @destination.id, user_id: @user.id)
    assert_nil @source.reload.parent_id
  end

  # The header action is the only move entry point now, so the root page -- which
  # has no current creative to act on -- has to lead somewhere rather than open an
  # empty dialog. It starts select mode and puts the caret on the first checkbox.
  test "the root action starts selection when nothing is selected" do
    visit collavre.creatives_path
    open_move_menu

    assert_no_selector "dialog[open][data-creative-move-target]"
    # The toggle lives inside the menu the action just closed, so its state is
    # only assertable with the visibility filter off.
    assert_selector "#select-creative-btn[aria-pressed='true']", visible: :all
    assert_equal "select-creative-checkbox",
      page.evaluate_script("document.activeElement.className")
    assert_nil @source.reload.parent_id
  end

  # A selection wins over the current creative, and every selected row moves --
  # the writable check now reads `can-write` off each row rather than a per-row
  # button that no longer exists.
  test "a multi-row selection moves every selected creative" do
    extra = Creative.create!(description: "Menu extra", user: @user)
    visit collavre.creatives_path
    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click
    find("#creative-#{@source.id} .select-creative-checkbox").click
    find("#creative-#{extra.id} .select-creative-checkbox").click

    open_move_menu
    assert_equal "move", find('[data-creative-move-target="mode"]').value
    find('[data-creative-move-target="destination"]').click
    find('[data-link-creative-target="input"]').set("Menu destination")
    find("#link-creative-modal .link-result-item[data-id='#{@destination.id}']").click
    find('[data-creative-move-target="confirm"]').click

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_equal @destination, @source.reload.parent
    assert_equal @destination, extra.reload.parent
  end

  private

  def open_move_menu(key = nil)
    toggle = find('[aria-controls="creative-overflow-menu"]')
    key ? toggle.send_keys(key) : toggle.click
    action = find('#creative-overflow-menu [data-creative-move-id]')
    key ? action.send_keys(key) : action.click
  end
end
