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

  # A filtered-to-nothing view still marks the tree loaded, so the header action
  # has a confirmed empty result to report. Without the in-app dialog the click
  # would look like a no-op, which is what the native alert did inside the
  # packaged desktop webview.
  test "the root action explains a view with nothing to select" do
    visit collavre.creatives_path(search: "no-such-creative-#{SecureRandom.hex(4)}")
    assert_selector "#creatives[data-loaded='true']", visible: :all

    open_move_menu

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.dnd.no_sources")
    assert_selector '[data-creative-move-target="announcement"]',
      text: I18n.t("collavre.dnd.no_sources"), visible: :all

    find("dialog[role='alertdialog'] .modal-dialog-btn-primary").click

    assert_no_selector "dialog[role='alertdialog']"
    assert_equal "creative-overflow-menu", page.evaluate_script("document.activeElement.getAttribute('aria-controls')")
    assert_nil @source.reload.parent_id
  end

  # A failed tree fetch is not a confirmed empty result. The header action has to
  # repeat the loading error instead of inviting the user to create a creative
  # that may already exist behind the failure.
  test "the root action reports a failed tree load" do
    assert_selector "#creatives[data-loaded='true']", visible: :all
    fail_tree_fetch
    reload_tree
    assert_selector "#creatives[data-load-state='error']", visible: :all

    open_move_menu

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.creatives.index.load_error")
    assert_selector '[data-creative-move-target="announcement"]',
      text: I18n.t("collavre.creatives.index.load_error"), visible: :all

    find("dialog[role='alertdialog'] .modal-dialog-btn-primary").click

    assert_no_selector "dialog[role='alertdialog']"
    assert_equal "creative-overflow-menu",
      page.evaluate_script("document.activeElement.getAttribute('aria-controls')")
  end

  # The failure can also land *after* the action was taken. The observer has to
  # keep waiting on the still-loading tree, hold focus on the visible launcher,
  # and then report the error rather than the empty-view copy.
  test "the root action waits for a late tree failure" do
    # The row alignment pass only reveals the header once rendered rows give it a
    # measurement, and a pending reload has no rows to measure. Wait for the real
    # launcher before injecting the failure, otherwise the test would be asserting
    # against a header that was never visible in the first place.
    assert_selector '[aria-controls="creative-overflow-menu"]'
    fail_tree_fetch(delay: 3000)
    reload_tree
    assert_no_selector "#creatives[data-loaded='true']", visible: :all

    open_move_menu

    assert_no_selector "dialog[role='alertdialog']", wait: 0.5
    assert_equal "creative-overflow-menu",
      page.evaluate_script("document.activeElement.getAttribute('aria-controls')")

    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.creatives.index.load_error"), wait: 10
  end

  # Archived rows cannot be reparented, and the rejection used to be a native
  # alert() -- invisible inside the packaged desktop webview. It has to be the
  # shared dialog, and closing it has to hand focus back to the launcher.
  test "an archived selection is refused with guidance" do
    archived = Creative.create!(description: "Menu archived", user: @user, archived_at: Time.current)
    visit collavre.creatives_path(show_archived: "true")
    select_rows(archived)

    open_move_menu

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.dnd.archived_selection")

    find("dialog[role='alertdialog'] .modal-dialog-btn-primary").click

    assert_no_selector "dialog[role='alertdialog']"
    assert_equal "creative-overflow-menu",
      page.evaluate_script("document.activeElement.getAttribute('aria-controls')")
    assert_nil archived.reload.parent_id
  end

  # One archived row poisons the whole batch: the move is refused outright rather
  # than silently dropping the archived member and moving the rest.
  test "a selection mixing archived rows is refused" do
    archived = Creative.create!(description: "Menu archived", user: @user, archived_at: Time.current)
    visit collavre.creatives_path(show_archived: "true")
    select_rows(@source, archived)

    open_move_menu

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.dnd.archived_selection")
    assert_nil @source.reload.parent_id
    assert_nil archived.reload.parent_id
  end

  private

  def open_move_menu(key = nil)
    toggle = find('[aria-controls="creative-overflow-menu"]')
    key ? toggle.send_keys(key) : toggle.click
    action = find('#creative-overflow-menu [data-creative-move-id]')
    key ? action.send_keys(key) : action.click
  end

  def select_rows(*creatives)
    creatives.each { |creative| assert_selector "#creative-#{creative.id}" }
    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click
    creatives.each { |creative| find("#creative-#{creative.id} .select-creative-checkbox").click }
  end

  # Fails only the tree JSON request (/creatives?format=json) so the rest of the
  # page keeps working.
  # A 500 takes the non-transient branch, which skips the network retries.
  def fail_tree_fetch(delay: 0)
    page.execute_script(<<~JS, delay)
      const wait = arguments[0]
      const original = window.fetch
      window.fetch = (input, init) => {
        const url = typeof input === 'string' ? input : input?.url
        if (url && url.includes('format=json')) {
          return new Promise((resolve) => setTimeout(
            () => resolve(new Response('{}', { status: 500 })), wait))
        }
        return original(input, init)
      }
    JS
  end

  # The archived toggle is the real control that clears data-loaded and refetches;
  # it is rendered hidden until archived rows exist, so it is clicked from script.
  def reload_tree
    page.execute_script("document.getElementById('toggle-archived-btn').click()")
  end
end
