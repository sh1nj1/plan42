require_relative "../application_system_test_case"

# Global control rules (font inheritance, muted tokens, primary/secondary
# action rows, topic chip inputs) are shared by many screens, so they are
# measured against the stylesheets the app actually serves, in every theme.
class GlobalControlsCssTest < ApplicationSystemTestCase
  FIXTURE = <<~HTML.freeze
    <div class="popup-box">
      <span class="topic-tag active"><input class="topic-edit-input"></span>
      <span class="topic-tag">#Main<button class="delete-topic-btn">×</button></span>
      <input class="topic-input">
    </div>
    <form class="stacked-form">
      <input type="submit" class="primary-action-button" value="Save 저장">
      <button type="button" class="secondary-action-button">Cancel 취소</button>
    </form>
    <span class="text-muted">Help</span>
    <small class="form-text">Help</small>
    <div class="comments-popup-actions"><button class="popup-close-btn">×</button></div>
    <form id="new-comment-form" style="width:280px"><textarea></textarea></form>
  HTML

  THEMES = {
    "light-mode" => { scheme: "light", muted: "rgb(102, 102, 102)" },
    "dark-mode" => { scheme: "light", muted: "rgb(170, 170, 170)" },
    "" => { scheme: "dark", muted: "rgb(170, 170, 170)" }
  }.freeze

  setup do
    @user = User.create!(
      email: "global-controls-css@example.com",
      password: SystemHelpers::PASSWORD,
      name: "GlobalControlsCssUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Root", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
  end

  teardown { emulate_color_scheme(nil) }

  test "global controls retain theme, focus, and compact geometry" do
    visit root_path
    assert_selector "#creative-#{@creative.id}", wait: 5
    page.current_window.resize_to(375, 812)
    page.execute_script("document.body.innerHTML = arguments[0]", FIXTURE)

    THEMES.each do |body_class, expected|
      emulate_color_scheme(expected[:scheme])
      page.execute_script("document.body.className = arguments[0]", body_class)

      assert_topic_inputs(body_class)
      assert_action_geometry(body_class, expected[:muted])
    end
  end

  private

  def emulate_color_scheme(scheme)
    features = scheme ? [ { name: "prefers-color-scheme", value: scheme } ] : []
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: features)
  end

  def assert_topic_inputs(theme)
    %w[.topic-input .topic-edit-input].each do |selector|
      style = page.evaluate_script(<<~JS, selector)
        (() => {
          const input = document.querySelector(arguments[0])
          input.focus()
          const style = getComputedStyle(input)
          return [style.borderLeftWidth, style.borderRightWidth, style.boxShadow]
        })()
      JS
      assert_equal [ "1px", "1px", "none" ], style, "#{selector} focus border in #{theme.inspect}"
    end

    topics = page.evaluate_script(<<~JS)
      (() => {
        const box = (selector) => document.querySelector(selector).getBoundingClientRect()
        const editTag = getComputedStyle(document.querySelector('.topic-edit-input').parentElement)
        return {
          edit: [box('.topic-edit-input').width, editTag.paddingLeft, editTag.backgroundColor],
          input: [box('.topic-input').width, box('.topic-input').height],
          close: box('.delete-topic-btn').height
        }
      })()
    JS
    assert_equal [ 80, "0px", "rgba(0, 0, 0, 0)" ], topics["edit"], "topic rename input in #{theme.inspect}"
    assert_equal [ 100, 26 ], topics["input"], "new topic input in #{theme.inspect}"
    assert_operator topics["close"], :<, 20, "topic close button height in #{theme.inspect}"
  end

  def assert_action_geometry(theme, muted)
    # :focus-visible only matches keyboard focus, so tab in from the field before it.
    find(".topic-input").send_keys(:tab)
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const box = (selector) => document.querySelector(selector).getBoundingClientRect()
        const color = (selector, property) => getComputedStyle(document.querySelector(selector))[property]
        const primary = document.activeElement
        return {
          focused: primary.className,
          close: [box('.popup-close-btn').width, box('.popup-close-btn').height],
          area: box('#new-comment-form textarea').width,
          primary: box('.primary-action-button').height,
          secondary: box('.secondary-action-button').height,
          bg: color('.primary-action-button', 'backgroundColor'),
          muted: color('.text-muted', 'color'),
          helper: color('.form-text', 'color'),
          outline: getComputedStyle(primary).outlineStyle
        }
      })()
    JS
    assert_equal "primary-action-button", geometry["focused"]
    assert_equal [ 28, 28 ], geometry["close"], "popup close button in #{theme.inspect}"
    assert_equal 280, geometry["area"], "chat textarea fills its form in #{theme.inspect}"
    assert_operator geometry["primary"], :>=, 36
    assert_equal geometry["primary"], geometry["secondary"], "action row heights in #{theme.inspect}"
    assert_equal "rgb(35, 122, 59)", geometry["bg"], "primary action fill in #{theme.inspect}"
    assert_equal muted, geometry["muted"], ".text-muted in #{theme.inspect}"
    assert_equal geometry["muted"], geometry["helper"], ".form-text in #{theme.inspect}"
    assert_equal "solid", geometry["outline"], "primary action focus ring in #{theme.inspect}"
  end
end
