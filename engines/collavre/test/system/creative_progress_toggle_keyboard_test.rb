require_relative "../application_system_test_case"

# The leaf progress checkbox is keyboard reachable, so Space activates it. Space
# runs the input's own activation behavior: the browser flips `checked` before
# the click reaches the row handler, and cancelling that click would flip it back
# once dispatch finishes. jsdom models the restore as an inversion rather than the
# spec's reassignment, so the keyboard path is verified in a real browser here.
class CreativeProgressToggleKeyboardTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @leaf = Creative.create!(description: "Leaf", user: @user, progress: 0)

    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creatives_path
  end

  def toggle_selector
    "#creative-#{@leaf.id} .progress-toggle-wrap"
  end

  def focus_checkbox
    selector = "#{toggle_selector} .progress-toggle-checkbox"
    assert_selector selector, visible: :all
    # The PATCH response and broadcast can replace the row between Capybara's
    # lookup and Selenium's next command. Pass the selector instead of a node so
    # the browser resolves and focuses the current checkbox atomically.
    page.execute_script("document.querySelector(arguments[0]).focus()", selector)
    assert checkbox_focused?, "expected the progress checkbox to hold focus"
  end

  def checkbox_focused?
    page.evaluate_script(<<~JS)
      !!document.activeElement &&
        document.activeElement.classList.contains('progress-toggle-checkbox') &&
        document.activeElement.closest('[data-creative-id="#{@leaf.id}"]') != null
    JS
  end

  def assert_checkbox_keeps_focus(seconds: 3)
    deadline = Time.current + seconds
    while Time.current < deadline
      assert checkbox_focused?, "expected focus to stay on the checkbox across every re-render"
      sleep 0.2
    end
  end

  def press_space
    page.driver.browser.action.send_keys(:space).perform
  end

  def press_space_on_checkbox
    focus_checkbox
    press_space
  end

  test "space toggles a leaf between complete and incomplete" do
    assert_selector "#{toggle_selector}[data-current-progress='0']"

    press_space_on_checkbox

    assert_selector "#{toggle_selector}[data-current-progress='1']", wait: 5
    assert_selector "#{toggle_selector} .progress-toggle-checkbox:checked", visible: :all
    wait_for_network_idle(timeout: 10)
    assert_equal 1, @leaf.reload.progress

    press_space_on_checkbox

    assert_selector "#{toggle_selector}[data-current-progress='0']", wait: 5
    assert_no_selector "#{toggle_selector} .progress-toggle-checkbox:checked", visible: :all
    wait_for_network_idle(timeout: 10)
    assert_equal 0, @leaf.reload.progress
  end

  test "space unchecks a completed leaf before the request settles" do
    @leaf.update!(progress: 1)
    visit collavre.creatives_path
    assert_selector "#{toggle_selector}[data-current-progress='1']"

    # Stall the PATCH so the optimistic state stays observable: the box has to
    # read unchecked from the keystroke itself, not from the server's re-render.
    page.execute_script("window.fetch = () => new Promise(() => {})")
    press_space_on_checkbox

    assert_selector "#{toggle_selector}[data-current-progress='0']", wait: 5
    assert_no_selector "#{toggle_selector} .progress-toggle-checkbox:checked", visible: :all
  end

  # The server's markup replaces the toggle through unsafeHTML, so the focused
  # checkbox is discarded. Focus once and never again: the second press has to
  # land on the replacement, not scroll the page.
  test "focus survives the server re-render so space toggles back" do
    focus_checkbox
    press_space

    assert_selector "#{toggle_selector}[data-current-progress='1']", wait: 5
    wait_for_network_idle(timeout: 10)
    assert_equal 1, @leaf.reload.progress
    # The broadcast for this update re-renders the row a second time, after the
    # PATCH response already did, so focus has to survive both. Hold the
    # assertion open rather than sampling once: a single sample passes in the
    # gap between the two renders.
    assert_checkbox_keeps_focus

    press_space

    assert_selector "#{toggle_selector}[data-current-progress='0']", wait: 5
    wait_for_network_idle(timeout: 10)
    assert_equal 0, @leaf.reload.progress
  end

  # `pointer-events: none` on the saving row stops the mouse but not a checkbox
  # that already holds focus, so a second press before the PATCH settles would
  # send the opposite value and the two could settle out of order.
  test "space is ignored while the request is in flight" do
    page.execute_script(<<~JS)
      window.__patchCount = 0;
      window.fetch = () => { window.__patchCount += 1; return new Promise(() => {}); };
    JS

    press_space_on_checkbox
    assert_selector "#{toggle_selector}[data-current-progress='1']", wait: 5
    press_space

    assert_no_selector "#{toggle_selector}[data-current-progress='0']", wait: 2
    assert_selector "#{toggle_selector} .progress-toggle-checkbox:checked", visible: :all
    assert_equal 1, page.evaluate_script("window.__patchCount")
  end
end
