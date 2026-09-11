require_relative "../application_system_test_case"

# The context and user strips at the top of the chat get the same pinned
# add + list buttons the topic bar already has.
class ChatBarListPopupTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "chat-bar-list@example.com",
      password: SystemHelpers::PASSWORD,
      name: "ChatBarListUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Root", user: @user)
    @context = Creative.create!(description: "Context One", user: @user)
    @creative.update!(data: { "context_ids" => [ @context.id ] })

    resize_window_to
    sign_in_via_ui(@user)
  end

  def open_comments_popup
    visit root_path
    assert_selector "#creative-#{@creative.id}", wait: 5
    creative_row = find("#creative-#{@creative.id}")
    creative_row.hover
    within("#creative-#{@creative.id}") do
      find(".comments-btn").click
    end
    assert_selector "#comments-popup", wait: 5
    assert_docked_comments_loaded
  end

  test "context list button opens a searchable popup of the linked contexts" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    find("#comments-popup .context-list-btn").click
    assert_selector "#context-list-modal", visible: :visible, wait: 5
    # Caged inside the chat box, not appended to <body>
    assert_selector "#comments-popup #context-list-modal"

    within "#context-list-modal" do
      assert_selector ".entity-list-item", text: "Root"          # self context
      assert_selector ".entity-list-item", text: "Context One"
    end
  end

  test "context list button toggles an open popup closed" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    button = find("#comments-popup .context-list-btn")
    button.click
    assert_selector "#context-list-modal", visible: :visible, wait: 5
    assert_equal "true", button["aria-expanded"]

    button.click
    assert_no_selector "#context-list-modal", visible: :visible
    assert_equal "false", button["aria-expanded"]
  end

  test "selecting a context in the popup toggles it off and keeps the popup open" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    find("#comments-popup .context-list-btn").click
    assert_selector "#context-list-modal", visible: :visible, wait: 5

    within "#context-list-modal" do
      find("li.common-popup-item", text: "Context One").click
      assert_selector ".entity-list-item--muted", text: "Context One", wait: 5
    end
    assert_selector "#context-list-modal", visible: :visible
    assert_selector "#comment-contexts .context-chip.context-disabled", text: "Context One", wait: 5
  end

  test "the context add button sits outside the scrolling chip strip and matches the other add buttons" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    assert_selector "#comments-popup .comment-contexts-bar > .add-context-btn"
    assert_no_selector "#comment-contexts .add-context-btn"

    properties = %w[
      width height border-radius border-style border-width
      background-color color font-size line-height padding
    ]
    style_value_script = "getComputedStyle(document.querySelector(arguments[0])).getPropertyValue(arguments[1])"
    styles = %w[.add-context-btn .add-participant-btn].to_h do |selector|
      values = properties.to_h { |property| [ property, evaluate_script(style_value_script, selector, property) ] }
      [ selector, values ]
    end

    assert_equal styles.fetch(".add-participant-btn"), styles.fetch(".add-context-btn")
  end

  test "user list button opens a searchable popup and the picked user's profile menu" do
    open_comments_popup
    assert_selector "#comment-participants .comment-presence-avatar", wait: 10

    find("#comments-popup .participant-list-btn").click
    assert_selector "#participant-list-modal", visible: :visible, wait: 5
    assert_selector "#comments-popup #participant-list-modal"

    within "#participant-list-modal" do
      find("li.common-popup-item", text: @user.name).click
    end

    assert_no_selector "#participant-list-modal", visible: :visible
    assert_selector "#participant-user-menu-#{@user.id}", visible: :visible
    within "#participant-user-menu-#{@user.id}" do
      assert_text @user.email
      assert_link I18n.t("collavre.comments.user_menu.view_profile"),
        href: Collavre::Engine.routes.url_helpers.user_path(@user)
      click_button I18n.t("collavre.comments.user_menu.mention")
    end
    assert_equal "@#{@user.name}: ", find("#new-comment-form textarea").value
  end

  test "the user add button sits outside the scrolling avatar strip" do
    open_comments_popup
    assert_selector "#comment-participants .comment-presence-avatar", wait: 10

    assert_selector "#comments-popup .comment-participants-bar > .add-participant-btn"
    assert_no_selector "#comment-participants .add-participant-btn"
  end

  test "message author menu stays anchored below the avatar on mobile" do
    comment = Comment.create!(creative: @creative, user: @user, content: "Mobile menu anchor")
    resize_window_to(390, 844)
    open_comments_popup

    trigger_selector = "#comment_#{comment.id} .comment-user-menu-trigger"
    menu_selector = "#user_menu_comment_#{comment.id}"
    find(trigger_selector).click
    assert_selector menu_selector, visible: :visible

    gap = page.evaluate_script(<<~JS)
      (() => {
        const trigger = document.querySelector('#{trigger_selector}').getBoundingClientRect()
        const menu = document.querySelector('#{menu_selector}').getBoundingClientRect()
        return menu.top - trigger.bottom
      })()
    JS

    assert_in_delta 4, gap, 0.5
  end

  # The on-screen keyboard shrinks the visual viewport without touching
  # window.innerHeight, and comments--presence lifts the sheet clear of it. A
  # menu placed against innerHeight lands behind the keyboard; Selenium cannot
  # raise a keyboard, so stub the viewport the way the browser reports one.
  test "message author menu stays clear of the on-screen keyboard on mobile" do
    comment = Comment.create!(creative: @creative, user: @user, content: "Keyboard anchor")
    resize_window_to(390, 844)
    open_comments_popup

    trigger_selector = "#comment_#{comment.id} .comment-user-menu-trigger"
    menu_selector = "#user_menu_comment_#{comment.id}"
    keyboard_top = 344
    page.execute_script(<<~JS)
      window.__fakeViewport = { width: 390, height: #{keyboard_top}, offsetLeft: 0, offsetTop: 0,
                                addEventListener() {}, removeEventListener() {} }
      Object.defineProperty(window, 'visualViewport', { value: window.__fakeViewport, configurable: true })
    JS

    # Capybara's click asks chromedriver for the element region, which reads the
    # real window.visualViewport we just replaced. Dispatch the click ourselves.
    page.execute_script("document.querySelector('#{trigger_selector}').click()")
    assert_selector menu_selector, visible: :visible

    bottom = page.evaluate_script(<<~JS)
      document.querySelector('#{menu_selector}').getBoundingClientRect().bottom
    JS

    assert_operator bottom, :<=, keyboard_top
  end

  test "message author menu actions work on mobile" do
    comment = Comment.create!(creative: @creative, user: @user, content: "Mobile menu actions")
    resize_window_to(390, 844)
    open_comments_popup

    trigger_selector = "#comment_#{comment.id} .comment-user-menu-trigger"
    menu_selector = "#user_menu_comment_#{comment.id}"

    touch = page.driver.browser.action
    touch.add_pointer_input(:touch, "finger")
    touch.click(find(trigger_selector).native, device: "finger").perform
    within menu_selector do
      touch = page.driver.browser.action
      touch.add_pointer_input(:touch, "finger")
      touch.click(find_button(I18n.t("collavre.comments.user_menu.mention")).native, device: "finger").perform
    end
    assert_equal "@#{@user.name}: ", find("#new-comment-form textarea").value

    touch = page.driver.browser.action
    touch.add_pointer_input(:touch, "finger")
    touch.click(find(trigger_selector).native, device: "finger").perform
    within menu_selector do
      touch = page.driver.browser.action
      touch.add_pointer_input(:touch, "finger")
      touch.click(find_link(I18n.t("collavre.comments.user_menu.view_profile")).native, device: "finger").perform
    end
    assert_current_path Collavre::Engine.routes.url_helpers.user_path(@user)
  end

  test "draggable agent menu actions work on mobile" do
    agent = User.create!(
      email: "chat-bar-agent@ai.local",
      password: SystemHelpers::PASSWORD,
      name: "ChatBarAgent",
      email_verified_at: Time.current,
      notifications_enabled: false,
      llm_vendor: "google",
      llm_model: "gemini-1.5-flash",
      system_prompt: "Test agent"
    )
    CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
    resize_window_to(390, 844)
    open_comments_popup

    trigger_selector = "[data-comment-user-menu-user-id-value='#{agent.id}'] .comment-user-menu-trigger"
    menu_selector = "#participant-user-menu-#{agent.id}"
    assert_selector trigger_selector, wait: 10

    touch = page.driver.browser.action
    touch.add_pointer_input(:touch, "finger")
    touch.click(find(trigger_selector).native, device: "finger").perform
    within menu_selector do
      touch = page.driver.browser.action
      touch.add_pointer_input(:touch, "finger")
      touch.click(find_button(I18n.t("collavre.comments.user_menu.mention")).native, device: "finger").perform
    end
    assert_equal "@#{agent.name}: ", find("#new-comment-form textarea").value

    touch = page.driver.browser.action
    touch.add_pointer_input(:touch, "finger")
    touch.click(find(trigger_selector).native, device: "finger").perform
    within menu_selector do
      touch = page.driver.browser.action
      touch.add_pointer_input(:touch, "finger")
      touch.click(find_link(I18n.t("collavre.comments.user_menu.view_profile")).native, device: "finger").perform
    end
    assert_current_path Collavre::Engine.routes.url_helpers.user_path(agent)
  end
end
