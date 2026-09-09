require_relative "../application_system_test_case"

# Creative rows used to be capped by a viewport-based `max-width` on
# `.creative-content`. The three-panel workspace drops that cap (`max-width:
# none`) because a viewport width means nothing inside a grid column — but the
# flex wrappers between the column and the content kept their default
# `min-width: auto`, so they could not shrink below their contents' min-content
# width. Prose still wrapped (min-content is one word) while unbreakable blocks
# — code blocks and tables — burst out of the column and were clipped by the
# chat panel. These lock every content shape inside its column.
class WorkspaceContentWrapTest < ApplicationSystemTestCase
  THREE_PANEL_WIDTH = 1400
  TWO_PANEL_WIDTH = 1000

  # Sub-pixel layout rounding, not slack for a genuinely overflowing row.
  OVERFLOW_TOLERANCE_PX = 1

  LONG_URL = "https://example.com/#{'very-long-path-segment/' * 12}index.html".freeze
  LONG_KOREAN = ("이것은 줄바꿈이 제대로 되는지 확인하기 위한 아주 긴 한국어 문장입니다. " * 6).freeze
  CODE_LINE = "const #{'reallyLongIdentifierName' * 8} = computeSomethingExpensive();".freeze

  setup do
    @user = User.create!(
      email: "content-wrap@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Content Wrap",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true
    )
    # The root's description renders as the title row, which has its own flex
    # chain (.creative-row-start > h1.page-title > .creative-title-content) and
    # its own content class. Give it the unbreakable shapes too so the title
    # chain is held to the same containment rule as the child rows.
    @root = Creative.create!(
      description: "<p>Wrap fixtures</p><pre><code>#{CODE_LINE}</code></pre>#{wide_table_html}",
      user: @user
    )

    # One child per content shape. Code blocks and tables are the shapes that
    # regressed; the prose and URL rows guard the cases that kept working, so a
    # future fix for one cannot quietly break the other.
    [
      LONG_KOREAN,
      LONG_URL,
      "<pre><code>#{CODE_LINE}</code></pre>",
      wide_table_html
    ].each_with_index do |description, index|
      Creative.create!(description: description, user: @user, parent: @root, sequence: index)
    end

    sign_in_via_ui(@user)
  end

  [ THREE_PANEL_WIDTH, TWO_PANEL_WIDTH ].each do |width|
    test "no creative content overflows its column at #{width}px" do
      visit_workspace(width)

      overflowing = overflowing_rows

      assert_empty overflowing,
        "content overflows the workspace column at #{width}px: #{overflowing.inspect}"
    end
  end

  # The overflow check passes trivially if the rows never rendered, so prove the
  # fixtures are on screen and that the flex chain actually collapsed to the
  # column rather than the old 800px viewport cap.
  test "every fixture row renders and shares the column width" do
    visit_workspace(THREE_PANEL_WIDTH)

    widths = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('main .creative-content')).map(function (el) {
        return Math.round(el.getBoundingClientRect().width);
      });
    JS

    assert_operator widths.size, :>=, 4, "expected the four fixture rows to render"
    assert_operator widths.max, :<=, column_width.round,
      "a row is wider than the content column"
  end

  # The wrappers the fix touches are the ones that must reach `min-width: 0`;
  # asserting the computed value catches a regression even if a future layout
  # change happens to hide the overflow some other way.
  test "the flex wrappers between the column and the content can shrink" do
    visit_workspace(THREE_PANEL_WIDTH)

    [
      ".creative-row-start",
      ".creative-tree-li",
      ".indent1",
      ".creative-tree-title .page-title",
      ".creative-title-content"
    ].each do |selector|
      next if page.evaluate_script("document.querySelectorAll('main #{selector}').length").zero?

      assert_equal "0px", computed_style(selector, "min-width"),
        "#{selector} keeps min-width: auto, so it cannot shrink to the column"
    end
  end

  private

  def wide_table_html
    cells = (1..8).map { |i| "<td>column value #{i}</td>" }.join
    headers = (1..8).map { |i| "<th>Column header #{i}</th>" }.join
    "<table><thead><tr>#{headers}</tr></thead><tbody><tr>#{cells}</tr></tbody></table>"
  end

  def visit_workspace(width)
    resize_window_to(width, 900)
    visit collavre.creative_path(@root)
    assert_selector ".creative-workspace-shell"
    assert_selector "main .creative-content", minimum: 4, wait: 10
    wait_for_network_idle(timeout: 10)
  end

  # Compare against main's *padding box* rather than its border box: a row that
  # ends exactly on the padding edge is correctly contained, and main scrolls,
  # so its border box can be wider than what the user sees.
  def overflowing_rows
    page.evaluate_script(<<~JS)
      (function () {
        var main = document.querySelector('.creative-workspace-shell > main');
        var style = getComputedStyle(main);
        var limit = main.getBoundingClientRect().left + main.clientWidth -
                    parseFloat(style.paddingLeft || 0);
        return Array.from(document.querySelectorAll(
          'main .creative-content, main .creative-title-content'
        ))
          .filter(function (el) {
            return el.getBoundingClientRect().right > limit + #{OVERFLOW_TOLERANCE_PX};
          })
          .map(function (el) {
            return {
              text: (el.textContent || '').trim().slice(0, 40),
              right: Math.round(el.getBoundingClientRect().right),
              limit: Math.round(limit)
            };
          });
      })();
    JS
  end

  def column_width
    page.evaluate_script(
      "document.querySelector('.creative-workspace-shell > main').clientWidth"
    )
  end

  def computed_style(selector, property)
    page.evaluate_script(<<~JS)
      getComputedStyle(document.querySelector('main #{selector}')).getPropertyValue(#{property.to_json});
    JS
  end
end
