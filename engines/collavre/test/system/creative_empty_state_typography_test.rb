require_relative "../application_system_test_case"

# The empty-state concept card originally rendered its three facet labels
# (empty_state_facet_doc / _task / _chat) and the block label
# (empty_state_block_label) at --text-00 (8px), which is unreadable at normal
# viewing distance. These assert the readable floor from the design-token scale
# (--text-0 = 12px) so a future edit cannot silently drop back to --text-00,
# plus the layout guards that the larger type depends on.
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

  # Wider facet columns push the "a + b + c = block" equation closer to the card
  # edge, so at narrow viewports it now wraps where it previously did not. It may
  # wrap — it may not strand a "+" or "=" at the end of a row.
  test "the concept diagram never ends a row with a dangling operator" do
    [ 1400, 1200, 900, 768, 600, 420, 360 ].each do |width|
      resize_window_to(width, 800)

      row_endings = page.evaluate_script(<<~JS)
        (function () {
          // Walk the visual leaves (operators, facets, the result block) in DOM
          // order; a leaf whose left edge moves back toward the start of the
          // line means flex-wrap opened a new row.
          var leaves = Array.from(document.querySelectorAll(
            '.creative-empty-state-concept-diagram .creative-empty-state-op,' +
            '.creative-empty-state-concept-diagram .creative-empty-state-facet,' +
            '.creative-empty-state-concept-diagram .creative-empty-state-block'
          ));
          var rows = [], current = [], prevLeft = -Infinity;
          leaves.forEach(function (el) {
            var left = el.getBoundingClientRect().left;
            if (left <= prevLeft && current.length) { rows.push(current); current = []; }
            prevLeft = left;
            current.push(el);
          });
          if (current.length) rows.push(current);
          return rows.map(function (row) {
            return row[row.length - 1].classList.contains('creative-empty-state-op');
          });
        })();
      JS

      assert_operator row_endings.size, :>=, 1
      refute_includes row_endings, true, "at #{width}px a diagram row ends with a bare operator"
    end
  end

  private

  def computed_font_size_px(selector)
    page.evaluate_script(
      "parseFloat(getComputedStyle(document.querySelector(#{selector.to_json})).fontSize)"
    )
  end
end
