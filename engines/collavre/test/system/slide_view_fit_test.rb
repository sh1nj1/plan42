require_relative "../application_system_test_case"

class SlideViewFitTest < ApplicationSystemTestCase
  PRECISE_SLIDE = <<~HTML.squish
    <div class="ppt-slide ppt-slide--wide" data-ppt-slide="1" data-ppt-width="12192000" data-ppt-height="6858000"
         data-ppt-format="{}"><div class="ppt-slide-layout"></div></div>
  HTML
  STANDARD_SLIDE = '<div class="ppt-slide ppt-slide--standard" data-ppt-slide="2"><div class="ppt-slide-layout"></div></div>'.freeze

  setup do
    @user = User.create!(email: "slide-fit@example.com", password: SystemHelpers::PASSWORD,
                         name: "Slide Fit User", email_verified_at: Time.current, notifications_enabled: false)
    image = File.basename(Dir[Rails.public_path.join("icon-*.png")].first)
    @root = Creative.create!(user: @user, description: PRECISE_SLIDE)
    Creative.create!(user: @user, parent: @root, description: STANDARD_SLIDE)
    Creative.create!(user: @user, parent: @root, description: %(<p><img src="/#{image}" width="4000" height="3000"></p>))
    Creative.rebuild!
    sign_in_via_ui(@user)
  end

  test "presentation slides fill the screen and large images stay inside it on desktop" do
    resize_window_to(1600, 1000)
    visit collavre.slide_view_creative_path(@root)

    assert_slide_fills_screen(16.0 / 9)
    find("body").send_keys(:arrow_right)
    assert_selector "#slide-content .ppt-slide--standard"
    assert_slide_fills_screen(4.0 / 3)
    find("body").send_keys(:arrow_right)
    assert_selector "#slide-content img"
    assert_image_fits_screen
  end

  test "presentation slides and large images fit above the swipe area on mobile" do
    resize_window_to(390, 844)
    visit collavre.slide_view_creative_path(@root)

    assert_slide_fills_screen(16.0 / 9)
    visit collavre.slide_view_creative_path(@root, slide: 2)
    assert_selector "#slide-content img"
    assert_image_fits_screen
  end

  private

  def assert_slide_fills_screen(ratio)
    metrics = slide_metrics("#slide-content .ppt-slide")
    assert_in_delta ratio, metrics["width"].fdiv(metrics["height"]), 0.02
    # The slide grows until either the available width or height runs out.
    filled = [ metrics["width"].fdiv(metrics["viewWidth"]), metrics["height"].fdiv(metrics["viewHeight"]) ].max
    assert_operator filled, :>, 0.85, metrics.inspect
    assert_inside_view metrics
  end

  def assert_image_fits_screen
    assert_inside_view slide_metrics("#slide-content img")
  end

  def assert_inside_view(metrics)
    assert_operator metrics["bottom"], :<=, metrics["viewBottom"] + 1, metrics.inspect
    assert_operator metrics["right"], :<=, metrics["viewWidth"] + 1, metrics.inspect
    assert_not metrics["scrolls"], metrics.inspect
  end

  def slide_metrics(selector)
    evaluate_script(<<~JS)
      (() => {
        const view = document.getElementById('slide-view');
        const box = document.querySelector(#{selector.to_json}).getBoundingClientRect();
        return {
          width: box.width, height: box.height, bottom: box.bottom, right: box.right,
          viewWidth: view.clientWidth, viewHeight: view.clientHeight, viewBottom: view.getBoundingClientRect().bottom,
          scrolls: view.scrollHeight > view.clientHeight || view.scrollWidth > view.clientWidth
        };
      })()
    JS
  end
end
