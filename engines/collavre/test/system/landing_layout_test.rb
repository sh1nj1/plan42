require_relative "../application_system_test_case"

class LandingLayoutTest < ApplicationSystemTestCase
  test "landing sections fill the viewport without a boxed main background in both themes" do
    %w[/features /landing].each do |path|
      visit path
      assert_selector ".landing-features"

      [ 1440, 390 ].each do |width|
        resize_window_to(width, 900)
        %w[light dark].each do |theme|
          page.execute_script(<<~JS, theme)
            document.body.classList.toggle('dark-mode', arguments[0] === 'dark');
            document.body.classList.toggle('light-mode', arguments[0] === 'light');
          JS
          styles = page.evaluate_script(<<~JS)
            (() => {
              const main = document.querySelector('.landing-page > main');
              const css = getComputedStyle(main);
              return { maxWidth: css.maxWidth, padding: css.padding, background: css.backgroundColor,
                width: main.getBoundingClientRect().width, viewport: document.documentElement.clientWidth,
                sections: Array.from(main.querySelectorAll('.landing-section')).map(section => {
                  const rect = section.getBoundingClientRect();
                  return { left: rect.left, right: rect.right };
                }) };
            })()
          JS
          assert_equal "none", styles["maxWidth"], "#{path} #{theme} #{width}px"
          assert_equal "0px", styles["padding"]
          assert_equal "rgba(0, 0, 0, 0)", styles["background"]
          assert_in_delta styles["viewport"], styles["width"], 1
          assert styles["sections"].any?
          styles["sections"].each do |section|
            assert_in_delta 0, section["left"], 1
            assert_in_delta styles["viewport"], section["right"], 1
          end
        end
      end
    end
  end
end
