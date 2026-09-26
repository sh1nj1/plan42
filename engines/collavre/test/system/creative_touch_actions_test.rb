require_relative "../application_system_test_case"

class CreativeTouchActionsTest < ApplicationSystemTestCase
  driven_by :hovering_pointer_headless_chrome

  setup do
    @user = User.create!(email: "touch-actions@example.com", password: SystemHelpers::PASSWORD,
      name: "Touch Actions", email_verified_at: Time.current, notifications_enabled: false)
    @parent = Creative.create!(description: "Touch parent", user: @user)
    @creative = Creative.create!(description: "Touch target", user: @user, parent: @parent)
    @child = Creative.create!(description: "Touch child", user: @user, parent: @creative)
    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creatives_path(id: @parent.id)
    assert_selector row
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  [ 390, 1024 ].each do |width|
    test "touch actions work with one tap at #{width}px" do
      emulate_touch(width)
      tap("#{row} .comments-btn")
      assert_selector "#comments-popup", visible: :visible

      visit collavre.creatives_path(id: @parent.id)
      tap("#{row} .creative-toggle-btn")
      assert_selector "#creative-#{@child.id}", visible: :visible
      tap("#{row} .creative-toggle-btn")
      assert_no_selector "#creative-#{@child.id}", visible: :visible

      if width <= 768
        tap("#{row} .creative-content", swipe: 80)
      end
      tap("#{row} .edit-inline-btn")
      assert_selector "#inline-edit-form-element", visible: :visible
    end

    test "touch hover does not reveal hidden row controls at #{width}px" do
      emulate_touch(width)
      before = control_visibility
      find("#{row} .creative-content").hover
      assert_equal before, control_visibility
      assert_equal "visible", before.fetch(".creative-toggle-btn")
      assert_equal "visible", before.fetch(".comments-btn")
    end
  end

  test "desktop hover still reveals row actions" do
    page.driver.browser.action.move_to_location(0, 0).perform
    assert_equal "hidden", control_visibility.fetch(".edit-inline-btn")
    assert_equal "hidden", control_visibility.fetch(".comments-btn")
    find("#{row} .creative-content").hover
    assert_equal "visible", control_visibility.fetch(".edit-inline-btn")
    assert_equal "visible", control_visibility.fetch(".comments-btn")
  end

  private

  def row
    "#creative-#{@creative.id}"
  end

  def emulate_touch(width)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: width, height: 900, deviceScaleFactor: 1, mobile: true)
    assert page.evaluate_script("matchMedia('(hover: none)').matches")
  end

  # Dispatch an actual touch sequence, not WebDriver's mouse click.
  def tap(selector, swipe: 0)
    element = find(selector)
    element.scroll_to(:center)
    point = page.evaluate_script(<<~JS, element)
      ((element) => {
        const rect = element.getBoundingClientRect();
        return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
      })(arguments[0])
    JS
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchStart", touchPoints: [ point ])
    if swipe.positive?
      point["x"] += swipe
      page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchMove", touchPoints: [ point ])
    end
    page.driver.browser.execute_cdp("Input.dispatchTouchEvent", type: "touchEnd", touchPoints: [])
  end

  def control_visibility
    page.evaluate_script(<<~JS, row)
      Object.fromEntries(['.edit-inline-btn', '.creative-toggle-btn', '.comments-btn'].map(selector => {
        const element = document.querySelector(arguments[0]).querySelector(selector);
        return [selector, getComputedStyle(element).visibility];
      }))
    JS
  end
end
