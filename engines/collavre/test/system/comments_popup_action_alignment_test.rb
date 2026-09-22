require_relative "../application_system_test_case"

class CommentsPopupActionAlignmentTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "comments-action-alignment@example.com",
      password: SystemHelpers::PASSWORD,
      name: "CommentsActionAlignmentUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Root", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
  end

  test "close and fullscreen actions share centered dimensions" do
    visit root_path
    assert_selector "#creative-#{@creative.id}", wait: 5
    find("#creative-#{@creative.id}").hover
    within("#creative-#{@creative.id}") { find(".comments-btn").click }
    assert_selector "#comments-popup", visible: :visible, wait: 5

    dimensions = page.evaluate_script(<<~JS)
      (() => {
        const box = (selector) => {
          const rect = document.querySelector(selector).getBoundingClientRect()
          return {
            width: rect.width,
            height: rect.height,
            centerX: rect.left + rect.width / 2,
            centerY: rect.top + rect.height / 2
          }
        }

        return {
          fullscreenButton: box('.comments-popup-fullscreen'),
          closeButton: box('#close-comments-btn'),
          fullscreenIcon: box('[data-comments--popup-target="fullscreenIcon"] svg'),
          closeIcon: box('[data-comments--popup-target="closeIcon"] svg')
        }
      })()
    JS

    assert_equal 24, dimensions.dig("fullscreenButton", "width")
    assert_equal 24, dimensions.dig("fullscreenButton", "height")
    assert_equal 24, dimensions.dig("closeButton", "width")
    assert_equal 24, dimensions.dig("closeButton", "height")
    assert_equal 16, dimensions.dig("fullscreenIcon", "width")
    assert_equal 16, dimensions.dig("fullscreenIcon", "height")
    assert_equal 16, dimensions.dig("closeIcon", "width")
    assert_equal 16, dimensions.dig("closeIcon", "height")
    assert_in_delta dimensions.dig("fullscreenButton", "centerY"), dimensions.dig("closeButton", "centerY"), 0.01
    assert_in_delta dimensions.dig("closeButton", "centerX"), dimensions.dig("closeIcon", "centerX"), 0.01
    assert_in_delta dimensions.dig("closeButton", "centerY"), dimensions.dig("closeIcon", "centerY"), 0.01
  end
end
