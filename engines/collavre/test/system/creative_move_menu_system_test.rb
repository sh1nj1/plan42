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

  test "move guidance switches between desktop and mobile in both locales" do
    %w[en ko].each do |locale|
      @user.update!(locale: locale)
      visit collavre.creatives_path(id: @source.id)
      open_move_menu

      within 'dialog[open][data-creative-move-target="dialog"] > .modal-dialog-footer' do
        assert_selector ".desktop-only", text: I18n.t("collavre.dnd.drag_drop_hint", locale: locale)
        assert_no_selector ".mobile-only"
        resize_window_to(390, 844)
        assert_selector ".mobile-only", text: I18n.t("collavre.dnd.mobile_drag_drop_hint", locale: locale)
        assert_no_selector ".desktop-only"
        resize_window_to(1440, 900)
      end
    end
  end

  test "keyboard moves a creative using the shared destination picker" do
    visit collavre.creatives_path(id: @source.id)
    open_move_menu(:return)
    input = find('[data-inline-creative-picker-target="input"]')
    input.set("Menu destination")
    assert_selector "#creative-move-results .link-result-item[data-id='#{@destination.id}']"
    input.send_keys(:return)
    find('[data-creative-move-target="confirm"]').send_keys(:return)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "#workspace-creative-#{@source.id}[data-parent-id='#{@destination.id}']"
    assert_equal @destination, @source.reload.parent
  end

  test "floating destination stays below the input and clears stale selections on mobile" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    visit collavre.creatives_path(id: @source.id)
    open_move_menu
    input = find("#creative-move-destination")
    assert_equal "true", input["aria-expanded"]
    assert_selector "dialog[open] #creative-move-results"
    assert_no_selector "#link-creative-modal"
    assert_floating_destination
    input.set("Menu destination")
    find("#creative-move-results .link-result-item[data-id='#{@destination.id}']").click
    assert_equal "Menu destination", input.value
    assert_no_selector "#creative-move-results"
    assert_selector '[data-creative-move-target="confirm"]:not([disabled])'
    input.set("Different destination")
    assert_selector '[data-creative-move-target="confirm"][disabled]'
    assert_nil @source.reload.parent_id
    input.set("Menu destination")
    assert_selector "#creative-move-results .link-result-item"
    page.save_screenshot(Rails.root.join("tmp/screenshots/creative-move-mobile.png"))
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    resize_window_to(1440, 900)
    page.execute_script("document.body.classList.remove('dark-mode'); document.body.classList.add('light-mode')")
    assert_floating_destination
    page.save_screenshot(Rails.root.join("tmp/screenshots/creative-move-desktop.png"))
  end

  test "destination fallback stays below the input and supports selection without Popover API" do
    visit collavre.creatives_path(id: @source.id)
    page.execute_script(<<~JS)
      delete HTMLElement.prototype.showPopover
      delete HTMLElement.prototype.hidePopover
    JS
    open_move_menu
    assert_selector "#creative-move-results .link-tree-item"
    assert_no_selector "#creative-move-results[popover]", visible: :all
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const input = document.querySelector('#creative-move-destination').getBoundingClientRect()
        const list = document.querySelector('#creative-move-results').getBoundingClientRect()
        return { inputBottom: input.bottom, listTop: list.top, inputLeft: input.left, listLeft: list.left }
      })()
    JS
    assert_in_delta geometry["inputBottom"] + 4, geometry["listTop"], 1
    assert_in_delta geometry["inputLeft"], geometry["listLeft"], 1
    find("#creative-move-destination").send_keys(:escape)
    assert_no_selector "#creative-move-results"
    assert_selector "dialog[open][data-creative-move-target]"
    pick_destination
    find('[data-creative-move-target="confirm"]').click
    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_equal @destination, @source.reload.parent
  end

  [ true, false ].each do |popover|
    test "short visual viewport keeps destination rows clickable with popover #{popover}" do
      visit collavre.creatives_path(id: @source.id)
      unless popover
        page.execute_script("delete HTMLElement.prototype.showPopover; delete HTMLElement.prototype.hidePopover")
      end
      open_move_menu
      original_top = page.evaluate_script("document.querySelector('dialog[open]').style.top")
      page.execute_script(<<~JS)
        const viewport = new EventTarget()
        Object.assign(viewport, { offsetTop: 40, offsetLeft: 0, pageTop: 40, pageLeft: 0, scale: 1, width: 390, height: 260 })
        Object.defineProperty(window, 'visualViewport', { configurable: true, value: viewport })
        viewport.dispatchEvent(new Event('resize'))
      JS
      input = find("#creative-move-destination")
      input.set("Menu destination")
      assert_selector "#creative-move-results .link-result-item[data-id='#{@destination.id}']"
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const input = document.querySelector('#creative-move-destination').getBoundingClientRect()
          const list = document.querySelector('#creative-move-results').getBoundingClientRect()
          return { inputTop: input.top, inputBottom: input.bottom, top: list.top, bottom: list.bottom, height: list.height }
        })()
      JS
      assert_operator geometry["inputTop"], :>=, 48
      assert_in_delta geometry["inputBottom"] + 4, geometry["top"], 1
      assert_operator geometry["height"], :>=, 30
      assert_operator geometry["bottom"], :<=, 292
      find("#creative-move-results .link-result-item[data-id='#{@destination.id}']").click
      assert_equal original_top, page.evaluate_script("document.querySelector('dialog[open]').style.top")
      find('[data-creative-move-target="confirm"]').click
      assert_no_selector "dialog[open][data-creative-move-target]"
      assert_equal @destination, @source.reload.parent
    end
  end

  test "workspace move menu offers a click-only path" do
    visit collavre.creatives_path(id: @source.id)
    open_move_menu
    find('[data-creative-move-target="destination"]').click
    find('[data-inline-creative-picker-target="input"]').set("Menu destination")
    find("#creative-move-results .link-result-item[data-id='#{@destination.id}']").click
    find('[data-creative-move-target="confirm"]').click

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "#workspace-creative-#{@source.id}[data-parent-id='#{@destination.id}']"
    assert_equal @destination, @source.reload.parent
  end

  test "Escape closes floating results before cancelling and restoring focus" do
    visit collavre.creatives_path(id: @source.id)
    open_move_menu(:return, delayed_chat_focus: true)
    assert_selector "#creative-move-results"
    find('[data-creative-move-target="destination"]').send_keys(:escape)
    assert_selector "dialog[open][data-creative-move-target]"
    assert_no_selector "#creative-move-results"
    find('[data-creative-move-target="destination"]').send_keys(:escape)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_equal "creative-overflow-menu", page.evaluate_script("document.activeElement.getAttribute('aria-controls')")
    assert_nil @source.reload.parent_id
  end

  test "Escape from a tree toggle keeps the move dialog open" do
    Creative.create!(description: "Nested destination", parent: @destination, user: @user)
    visit collavre.creatives_path(id: @source.id)
    open_move_menu
    toggle = find("#creative-move-results .link-tree-item[data-id='#{@destination.id}'] .link-tree-toggle")
    page.execute_script("arguments[0].focus()", toggle)
    assert_equal "link-tree-toggle", page.evaluate_script("document.activeElement.className")
    page.driver.browser.switch_to.active_element.send_keys(:escape)
    assert_no_selector "#creative-move-results"
    assert_selector "dialog[open][data-creative-move-target]"
    assert_equal "creative-move-destination", page.evaluate_script("document.activeElement.id")
  end

  test "keyboard creates a link from a readable source without the workspace" do
    @user.update!(creative_workspace_enabled: false)
    @source.update!(user: users(:two))
    CreativeShare.create!(creative: @source, user: @user, permission: :read)
    visit collavre.creatives_path(id: @source.id)

    open_move_menu(:return)
    assert_selector '[data-creative-move-target="mode"] option[value="move"][disabled]', visible: :all
    assert_equal "link", find('[data-creative-move-target="mode"]').value
    input = find('[data-inline-creative-picker-target="input"]')
    input.set("Menu destination")
    assert_selector "#creative-move-results .link-result-item[data-id='#{@destination.id}']"
    input.send_keys(:return)
    find('[data-creative-move-target="confirm"]').send_keys(:return)

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert Creative.exists?(origin_id: @source.id, parent_id: @destination.id, user_id: @user.id)
    assert_nil @source.reload.parent_id
  end

  # The root page has no current creative to act on, so the header offers no move
  # action there at all -- the rest of the overflow menu is untouched.
  test "the root header offers no move action" do
    visit collavre.creatives_path
    assert_selector "#creative-#{@source.id}"
    find('[aria-controls="creative-overflow-menu"]').click

    assert_no_selector "#creative-overflow-menu [data-creative-move-id]", visible: :all
    assert_selector "#select-creative-btn", visible: :all
    assert_nil @source.reload.parent_id
  end

  # A selection wins over the current creative, and every selected row moves --
  # the writable check now reads `can-write` off each row rather than a per-row
  # button that no longer exists.
  test "a multi-row selection moves every selected creative" do
    holder = Creative.create!(description: "Menu holder", user: @user)
    first = Creative.create!(description: "Menu first child", user: @user, parent: holder)
    second = Creative.create!(description: "Menu second child", user: @user, parent: holder)
    visit collavre.creatives_path(id: holder.id)
    select_rows(first, second)

    open_move_menu
    assert_equal "move", find('[data-creative-move-target="mode"]').value
    find('[data-creative-move-target="destination"]').click
    find('[data-inline-creative-picker-target="input"]').set("Menu destination")
    find("#creative-move-results .link-result-item[data-id='#{@destination.id}']").click
    find('[data-creative-move-target="confirm"]').click

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_equal @destination, first.reload.parent
    assert_equal @destination, second.reload.parent
    assert_nil holder.reload.parent_id
  end

  # An archived parent keeps the selection-only launcher, and a view with no
  # active child still marks the tree loaded -- a confirmed empty result the
  # action has to report. Without the in-app dialog the click would look like a
  # no-op, which is what the native alert did inside the packaged desktop webview.
  test "the selection-only action explains a view with nothing to select" do
    visit collavre.creatives_path(id: archived_parent.id, show_archived: "true")
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
  test "the selection-only action reports a failed tree load" do
    visit collavre.creatives_path(id: archived_parent.id, show_archived: "true")
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
  test "the selection-only action waits for a late tree failure" do
    visit collavre.creatives_path(id: archived_parent.id, show_archived: "true")
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
    holder = Creative.create!(description: "Menu holder", user: @user)
    archived = Creative.create!(description: "Menu archived", user: @user, parent: holder, archived_at: Time.current)
    visit collavre.creatives_path(id: holder.id, show_archived: "true")
    select_rows(archived)

    open_move_menu

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.dnd.archived_selection")

    find("dialog[role='alertdialog'] .modal-dialog-btn-primary").click

    assert_no_selector "dialog[role='alertdialog']"
    assert_equal "creative-overflow-menu",
      page.evaluate_script("document.activeElement.getAttribute('aria-controls')")
    assert_equal holder, archived.reload.parent
  end

  # One archived row poisons the whole batch: the move is refused outright rather
  # than silently dropping the archived member and moving the rest.
  test "a selection mixing archived rows is refused" do
    holder = Creative.create!(description: "Menu holder", user: @user)
    active = Creative.create!(description: "Menu active", user: @user, parent: holder)
    archived = Creative.create!(description: "Menu archived", user: @user, parent: holder, archived_at: Time.current)
    visit collavre.creatives_path(id: holder.id, show_archived: "true")
    select_rows(active, archived)

    open_move_menu

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.dnd.archived_selection")
    assert_equal holder, active.reload.parent
    assert_equal holder, archived.reload.parent
  end

  # An archived parent is not a movable source, but its active children still
  # are. The header keeps the launcher with an empty ID so the action falls
  # through to selection instead of disappearing, and the archived parent -- the
  # title row -- never offers a checkbox of its own.
  %w[move link].each do |mode|
    test "an archived parent still lets its active children be #{mode}ed" do
      parent = Creative.create!(description: "Menu archived parent", user: @user, archived_at: Time.current)
      child = Creative.create!(description: "Menu active child", user: @user, parent: parent)
      visit collavre.creatives_path(id: parent.id, show_archived: "true")

      assert_selector "#creative-overflow-menu [data-creative-move-id='']", visible: :all
      assert_selector "#creative-#{child.id}"
      assert_no_selector "#creative-#{parent.id} .select-creative-checkbox", visible: :all

      open_move_menu
      assert_no_selector "dialog[open][data-creative-move-target]"
      assert_selector "#select-creative-btn[aria-pressed='true']", visible: :all

      find("#creative-#{child.id} .select-creative-checkbox").click
      open_move_menu

      # An active child is writable, so move stays available and link is a choice.
      assert_equal "move", find('[data-creative-move-target="mode"]').value
      find(%([data-creative-move-target="mode"] option[value="#{mode}"])).select_option
      find('[data-creative-move-target="destination"]').click
      find('[data-inline-creative-picker-target="input"]').set("Menu destination")
      find("#creative-move-results .link-result-item[data-id='#{@destination.id}']").click
      find('[data-creative-move-target="confirm"]').click

      assert_no_selector "dialog[open][data-creative-move-target]"
      if mode == "move"
        assert_equal @destination, child.reload.parent
      else
        # Link leaves the child where it is and adds a shell under the target.
        assert_equal parent, child.reload.parent
        shell = @destination.children.reload.find { |row| row.origin_id == child.id }
        assert shell, "expected a linked shell for the child under the destination"
      end
      assert_nil parent.reload.parent_id
      assert parent.reload.archived?
    end
  end

  # The header action reads `.select-creative-checkbox:checked` document-wide,
  # so a selection surviving a Back navigation would silently replace the
  # creative on screen. This pins the restored page to the current creative and
  # keeps a fresh selection working afterwards. Note that it passes without the
  # controller reset too: <creative-tree-row> rebuilds its checkbox when the
  # restored snapshot upgrades, so checkedness never actually survives here.
  test "a restored history snapshot drops the hidden selection" do
    child = Creative.create!(description: "Menu child", user: @user, parent: @source)
    visit collavre.creatives_path(id: @source.id)
    assert_selector "#creative-#{child.id} .select-creative-checkbox", visible: :all

    select_rows(child)
    assert_selector "#creative-#{child.id} .select-creative-checkbox:checked", visible: :all

    page.execute_script("window.Turbo.visit('#{collavre.creatives_path(id: @destination.id)}')")
    assert_no_selector "#creative-#{child.id}"

    page.go_back

    assert_selector "#creative-#{child.id} .select-creative-checkbox", visible: :all
    assert_selector "#select-creative-btn[aria-pressed='false']", visible: :all
    assert_no_selector ".select-creative-checkbox:checked", visible: :all

    # The launcher falls back to the creative on screen, so the move has to land
    # on the source and leave the previously selected child where it is.
    mark_row_before_tree_refresh(child)
    open_move_menu
    pick_destination
    find('[data-creative-move-target="confirm"]').click

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_row_replaced_by_tree_refresh(child)
    assert_equal @destination, @source.reload.parent
    assert_equal @source, child.reload.parent

    # Selecting again after the restore still reaches the child.
    select_rows(child)
    assert_selector "#creative-#{child.id} .select-creative-checkbox:checked", visible: :all
    open_move_menu
    assert_selector "dialog[open][data-creative-move-target]"
    pick_destination
    find('[data-creative-move-target="confirm"]').click

    assert_no_selector "dialog[open][data-creative-move-target]"
    assert_equal @destination, child.reload.parent
  end

  private

  def assert_floating_destination
    assert_selector "#creative-move-results:popover-open"
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const input = document.querySelector('#creative-move-destination').getBoundingClientRect()
        const list = document.querySelector('#creative-move-results').getBoundingClientRect()
        const dialog = document.querySelector('dialog[open]').getBoundingClientRect()
        return { inputBottom: input.bottom, listBottom: list.bottom, listTop: list.top, dialogHeight: dialog.height }
      })()
    JS
    assert_operator geometry["listTop"], :>=, geometry["inputBottom"]
    assert_operator geometry["listTop"], :>=, 0
    find("#creative-move-destination").send_keys(:escape)
    assert_selector "dialog[open][data-creative-move-target]"
    assert_in_delta geometry["dialogHeight"], find("dialog[open]").rect.height, 1
    find("#creative-move-destination").click
  end

  # The selection-only launcher (an empty move id) now lives on archived parents
  # alone, so the fallback paths are exercised from one.
  def archived_parent
    @archived_parent ||= Creative.create!(
      description: "Menu archived parent", user: @user, archived_at: Time.current
    )
  end

  def open_move_menu(key = nil, delayed_chat_focus: false)
    toggle = find('[aria-controls="creative-overflow-menu"]')
    key ? toggle.send_keys(key) : toggle.click
    action = find('#creative-overflow-menu [data-creative-move-id]')
    if delayed_chat_focus
      # Reproduce a comments response arriving while the menu action has focus.
      page.evaluate_async_script(<<~JS, action)
        const action = arguments[0]
        const done = arguments[arguments.length - 1]
        action.focus()
        const popup = document.getElementById('comments-popup')
        const form = window.Stimulus.getControllerForElementAndIdentifier(popup, 'comments--form')
        form.focusTextarea()
        requestAnimationFrame(() => done())
      JS
      assert page.evaluate_script("document.activeElement === arguments[0]", action),
        "Delayed chat loading must preserve focus on the move action"
    end
    key ? action.send_keys(key) : action.click
  end

  def pick_destination(creative = @destination)
    find('[data-creative-move-target="destination"]').click
    find('[data-inline-creative-picker-target="input"]').set(creative.description)
    find("#creative-move-results .link-result-item[data-id='#{creative.id}']").click
  end

  def select_rows(*creatives)
    creatives.each { |creative| assert_selector "#creative-#{creative.id}" }
    find('[aria-controls="creative-overflow-menu"]').click
    find("#select-creative-btn").click
    creatives.each { |creative| find("#creative-#{creative.id} .select-creative-checkbox").click }
  end

  def mark_row_before_tree_refresh(creative)
    page.execute_script(<<~JS, "#creative-#{creative.id}")
      document.querySelector(arguments[0]).dataset.beforeMoveRefresh = 'true'
    JS
  end

  def assert_row_replaced_by_tree_refresh(creative)
    assert_no_selector "#creative-#{creative.id}[data-before-move-refresh]", visible: :all, wait: 10
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
