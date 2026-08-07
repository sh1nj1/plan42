require_relative "../application_system_test_case"

# The empty-state concept card originally rendered its facet labels
# ("트리 구조 문서 조각", "실행 가능한 작업 (진행률)", "관련 대화 채널") and the
# block label ("크리에이티브 1블록") at --text-00 (8px), which is unreadable at
# normal viewing distance. These assert the readable floor from the design-token
# scale (--text-0 = 12px) so a future edit cannot silently drop back to --text-00.
class CreativeEmptyStateTypographyTest < ApplicationSystemTestCase
  READABLE_FLOOR_PX = 12

  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @parent_creative = Creative.create!(description: "Parent", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creative_path(@parent_creative)
    wait_for_network_idle(timeout: 10)
    assert_selector ".creative-empty-state", visible: true, wait: 5
  end

  test "concept card text renders at or above the readable token size" do
    {
      ".creative-empty-state-facet-label" => "facet label",
      ".creative-empty-state-block-label" => "block label",
      ".creative-empty-state-concept-title" => "concept title",
      ".creative-empty-state-concept-caption" => "concept caption",
      ".creative-empty-state-heading" => "heading"
    }.each do |selector, label|
      assert_operator computed_font_size_px(selector), :>=, READABLE_FLOOR_PX,
        "#{label} (#{selector}) renders below the #{READABLE_FLOOR_PX}px readable floor"
    end
  end

  # Bumping the labels without widening the facet column would shred the longest
  # label into a four-line stack, so guard the column width too.
  test "the longest facet label wraps to at most two lines" do
    line_counts = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('.creative-empty-state-facet-label')).map(function (el) {
        return Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight));
      });
    JS

    assert_equal 3, line_counts.size
    line_counts.each { |lines| assert_operator lines, :<=, 2, "facet label wrapped to #{lines} lines" }
  end

  private

  def computed_font_size_px(selector)
    page.evaluate_script(
      "parseFloat(getComputedStyle(document.querySelector(#{selector.to_json})).fontSize)"
    )
  end
end
