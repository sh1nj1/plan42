require_relative "../application_system_test_case"

class PptShapeLayersTest < ApplicationSystemTestCase
  test "filled preset shapes paint their labels above SVG on repeated formatting" do
    visit "about:blank"
    stylesheet = Collavre::Engine.root.join("app/assets/stylesheets/collavre/creatives.css").read
    renderer = Collavre::Engine.root.join("app/javascript/lib/ppt_media.js").read.gsub("export function", "function")
    execute_script(<<~JS, stylesheet, renderer)
      document.head.innerHTML = '<style></style>';
      document.querySelector('style').textContent = arguments[0];
      document.body.innerHTML = '<div id="fixture"></div>';
      const render = new Function(arguments[1] + '; return renderPptShape;')();
      ['triangle', 'diamond', 'rightArrow'].forEach((shape, index) => {
        const element = document.createElement('div');
        element.className = 'ppt-slide-text';
        element.style.cssText = `position:absolute;left:${index * 220}px;top:0;width:200px;height:200px`;
        element.innerHTML = '<p style="margin:80px 0 0;text-align:center;color:black">Visible label</p>';
        document.getElementById('fixture').append(element);
        const data = {shape, fill: '#FFFFFF', stroke: '#000000', strokeWidth: 0.1};
        render(element, data);
        render(element, data);
        // Hit testing follows paint order when both layers receive pointers.
        element.querySelector('svg').style.pointerEvents = 'auto';
      });
    JS
    assert_selector ".ppt-preset-rendered > svg", count: 3
    layers = evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('.ppt-preset-rendered')).map(element => {
        const label = element.querySelector('p');
        const box = label.getBoundingClientRect();
        return document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2) === label;
      })
    JS
    assert_equal [ true, true, true ], layers
    # A later slide shape must still paint over the whole earlier shape.
    assert evaluate_script(<<~JS)
      (() => {
        const overlay = document.createElement('div');
        overlay.style.cssText = 'position:absolute;left:0;top:0;width:200px;height:200px;background:red';
        document.getElementById('fixture').append(overlay);
        const label = document.querySelector('.ppt-preset-rendered > p').getBoundingClientRect();
        return document.elementFromPoint(label.x + label.width / 2, label.y + label.height / 2) === overlay;
      })()
    JS
  end
end
