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

  def press_space_on_checkbox
    checkbox = find("#{toggle_selector} .progress-toggle-checkbox", visible: :all)
    page.execute_script("arguments[0].focus()", checkbox)
    assert page.evaluate_script("document.activeElement.classList.contains('progress-toggle-checkbox')"),
           "expected the progress checkbox to hold focus"
    page.driver.browser.action.send_keys(:space).perform
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
end
