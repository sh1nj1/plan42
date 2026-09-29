require_relative "../application_system_test_case"

class ToolCategoryAlignmentTest < ApplicationSystemTestCase
  test "category controls stay centered and compact when collapsed and expanded" do
    users(:one).update!(email_verified_at: Time.current)
    sign_in_via_ui(users(:one), password: "password")

    [ collavre.new_ai_users_path, collavre.edit_ai_user_path(users(:ai_bot)) ].each do |path|
      [ 375, 1200 ].each do |width|
        resize_window_to(width, 900)
        visit path
        category = first(".tool-category")
        within(category) do
          assert_selector ".tool-category-disclosure[aria-expanded='false']"
          assert_controls_aligned
          find(".tool-category-disclosure").click
          assert_selector ".tool-category-disclosure[aria-expanded='true']"
          assert_controls_aligned
        end
      end
    end
  end

  private

  def assert_controls_aligned
    positions = page.evaluate_script(<<~JS)
      (() => {
        const heading = document.querySelector('.tool-category-heading');
        const box = selector => heading.querySelector(selector).getBoundingClientRect();
        const button = box('.tool-category-disclosure');
        const icon = box('.tool-category-disclosure svg');
        const checkbox = box('.tool-category-toggle');
        const label = box('strong');
        const centerY = rect => rect.top + rect.height / 2;
        return {
          iconY: centerY(icon), checkboxY: centerY(checkbox), labelY: centerY(label),
          gap: checkbox.left - button.right, iconSize: icon.width, buttonSize: button.width
        };
      })()
    JS

    assert_in_delta positions.fetch("iconY"), positions.fetch("checkboxY"), 1
    assert_in_delta positions.fetch("iconY"), positions.fetch("labelY"), 1
    assert_in_delta 4, positions.fetch("gap"), 0.5
    assert_in_delta 16, positions.fetch("iconSize"), 0.5
    assert_in_delta 16, positions.fetch("buttonSize"), 0.5
  end
end
