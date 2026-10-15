require_relative "../application_system_test_case"

class LandingLayoutTest < ApplicationSystemTestCase
  test "home feature background spans the viewport without changing content geometry" do
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
                band: (() => {
                  const band = main.querySelector('#features');
                  if (!band) return null;
                  const paint = getComputedStyle(band, '::before');
                  return { width: parseFloat(paint.width), background: paint.backgroundColor,
                    expected: getComputedStyle(band).backgroundColor,
                    cards: band.querySelectorAll('.landing-feature-card').length };
                })(),
                width: main.getBoundingClientRect().width, viewport: document.documentElement.clientWidth,
                sections: Array.from(main.querySelectorAll('.landing-section')).map(section => {
                  const rect = section.getBoundingClientRect();
                  return { left: rect.left, right: rect.right };
                }) };
            })()
          JS
          assert_equal "960px", styles["maxWidth"], "#{path} #{theme} #{width}px"
          assert_equal(width > 768 ? "0px 16px 64px" : "0px 4.8px 64px", styles["padding"])
          refute_equal "rgba(0, 0, 0, 0)", styles["background"]
          if path == "/landing"
            assert_in_delta styles["viewport"], styles["band"]["width"], 1
            assert_equal styles["band"]["expected"], styles["band"]["background"]
            assert_equal 4, styles["band"]["cards"]
          else
            assert_nil styles["band"]
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
