require_relative "../application_system_test_case"

class CreativeRowHighlightTest < ApplicationSystemTestCase
  test "chat highlight uses an inset accent and tint without changing row geometry" do
    visit "/session/new"
    page.execute_script(<<~JS)
      const fixture = document.createElement('creative-tree-row');
      fixture.id = 'highlight-fixture';
      fixture.style.cssText = '--color-active: rgb(100, 150, 200); position: fixed; top: 100px; left: 100px; width: 400px; z-index: 99999';
      document.body.appendChild(fixture);
    JS
    row = find("#highlight-fixture .creative-row")
    before = row.rect
    page.execute_script("document.querySelector('#highlight-fixture').classList.add('chat-active')")

    styles = page.evaluate_script(<<~JS)
      (() => {
        const style = getComputedStyle(document.querySelector('#highlight-fixture .creative-row'));
        return { border: style.borderLeftWidth, shadow: style.boxShadow, background: style.backgroundColor };
      })()
    JS
    assert_equal "0px", styles.fetch("border")
    assert_equal "rgb(100, 150, 200) 3px 0px 0px 0px inset", styles.fetch("shadow")
    assert_match(/0\.06\)/, styles.fetch("background"))
    assert_equal before, row.rect

    %w[light-mode dark-mode].each do |theme|
      page.execute_script("document.body.classList.remove('light-mode', 'dark-mode'); document.body.classList.add(arguments[0])", theme)
      assert_equal styles.fetch("shadow"), page.evaluate_script("getComputedStyle(document.querySelector('#highlight-fixture .creative-row')).boxShadow")
    end

    row.hover
    assert_equal styles.fetch("background"), page.evaluate_script("getComputedStyle(document.querySelector('#highlight-fixture .creative-row')).backgroundColor")
    assert_equal "5px", page.evaluate_script("getComputedStyle(document.querySelector('#highlight-fixture .creative-row')).borderRadius")
    assert_match(/inset/, page.evaluate_script("getComputedStyle(document.querySelector('#highlight-fixture .creative-row')).boxShadow"))
  end
end
