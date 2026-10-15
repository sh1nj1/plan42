require_relative "../application_system_test_case"

class LandingLayoutTest < ApplicationSystemTestCase
  test "feature index hides the main background without changing page geometry in both themes" do
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
          assert_equal "960px", styles["maxWidth"], "#{path} #{theme} #{width}px"
          assert_equal(width > 768 ? "0px 16px 64px" : "0px 4.8px 64px", styles["padding"])
          if path == "/features"
            assert_equal "rgba(0, 0, 0, 0)", styles["background"]
          else
            refute_equal "rgba(0, 0, 0, 0)", styles["background"]
          end
          assert_operator styles["width"], :<=, 960
          assert styles["sections"].any?
          styles["sections"].each do |section|
            assert_operator section["left"], :>, 0
            assert_operator section["right"], :<, styles["viewport"]
          end
        end
      end
    end
  end
end
