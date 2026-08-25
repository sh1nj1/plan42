require_relative "../application_system_test_case"

# The leaf progress checkbox is a hover action on pointer devices: a resting row
# stays quiet and the box appears with the row's other hover controls. Touch
# devices have no hover to reveal it, so the box stays visible there. Both
# branches are CSS-only, so they are verified in a real browser.
class CreativeProgressToggleVisibilityTest < ApplicationSystemTestCase
  # Headless runners report no pointer at all, so the hover branch needs a
  # browser pinned to a desktop pointer to be observable.
  driven_by :hovering_pointer_headless_chrome

  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @incomplete = Creative.create!(description: "Incomplete", user: @user, progress: 0)
    @complete = Creative.create!(description: "Complete", user: @user, progress: 1)

    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creatives_path
    assert page.evaluate_script("matchMedia('(hover: hover)').matches"),
      "expected the test browser to report a hovering pointer"
    assert_selector "#{wrap_selector(@incomplete)}[data-current-progress='0']"
    assert_selector "#{wrap_selector(@complete)}[data-current-progress='1']"
  end

  teardown do
    reset_touch_emulation
  end

  def row_selector(creative)
    "#creative-#{creative.id} .creative-row"
  end

  def wrap_selector(creative)
    "#creative-#{creative.id} .progress-toggle-wrap"
  end

  def opacity(selector)
    page.evaluate_script(<<~JS)
      (function () {
        const element = document.querySelector("#{selector}");
        return element ? window.getComputedStyle(element).opacity : null;
      })()
    JS
  end

  # The reveal is a 0.12s fade, so sample until it settles rather than reading
  # the value mid-transition.
  def assert_opacity(selector, expected, message)
    deadline = Time.current + Capybara.default_max_wait_time
    actual = nil
    while Time.current < deadline
      actual = opacity(selector)
      break if actual.to_f.round(2) == expected
      sleep 0.05
    end
    assert_equal expected, actual.to_f.round(2), "#{message} (opacity was #{actual.inspect})"
  end

  def hover_row(creative)
    find(row_selector(creative)).hover
  end

  # Park the pointer in the viewport's corner: hovering another element could
  # land on a second creative row, which is the state under test.
  def unhover
    page.driver.browser.action.move_to_location(0, 0).perform
  end

  # `Emulation.setEmulatedMedia` does not cover `hover`/`pointer`; only device
  # emulation flips them, so a touch device is emulated the way DevTools does it.
  def emulate_touch_device
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 3, mobile: true
    )
    assert page.evaluate_script("matchMedia('(hover: none)').matches"),
      "expected the emulated device to report no hover capability"
  end

  def reset_touch_emulation
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  rescue StandardError
    # The browser is already gone when a test tears down after a failure.
  end

  test "a pointer device hides the checkbox until the row is hovered" do
    checkbox = "#{wrap_selector(@incomplete)} .progress-toggle-checkbox"
    assert_opacity checkbox, 0.0, "expected a resting row to hide the checkbox"

    hover_row(@incomplete)
    assert_opacity checkbox, 1.0, "expected row hover to reveal the checkbox"

    unhover
    assert_opacity checkbox, 0.0, "expected the checkbox to hide again once the pointer leaves"
  end

  test "a pointer device swaps a completed leaf's mark for the checkbox on row hover" do
    checkbox = "#{wrap_selector(@complete)} .progress-toggle-checkbox"
    mark = "#{wrap_selector(@complete)} .progress-toggle-mark"
    assert_opacity mark, 1.0, "expected a resting completed row to show the completion mark"
    assert_opacity checkbox, 0.0, "expected a resting completed row to hide the checkbox"

    hover_row(@complete)
    assert_opacity checkbox, 1.0, "expected row hover to reveal the checked box"
    assert_opacity mark, 0.0, "expected row hover to hide the completion mark"
  end

  test "keyboard focus reveals the checkbox without a pointer" do
    checkbox = "#{wrap_selector(@incomplete)} .progress-toggle-checkbox"
    assert_opacity checkbox, 0.0, "expected a resting row to hide the checkbox"

    page.execute_script("document.querySelector('#{checkbox}').focus()")

    assert_opacity checkbox, 1.0, "expected keyboard focus to reveal the checkbox"
  end

  test "a touch device keeps the checkbox visible without hover" do
    emulate_touch_device

    assert_opacity "#{wrap_selector(@incomplete)} .progress-toggle-checkbox", 1.0,
      "expected a touch device to keep the checkbox visible"
    assert_opacity "#{wrap_selector(@complete)} .progress-toggle-mark", 1.0,
      "expected a touch device to keep the completion mark visible"
  end
end
