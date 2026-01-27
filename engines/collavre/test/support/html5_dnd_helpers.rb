module Html5DndHelpers
  # copied from class Capybara::Selenium::Node module Html5Drag
  # and modified to add x_offset, y_offset
  HTML5_DRAG_DROP_SCRIPT = <<~JS
      function rectCenter(rect){
        return new DOMPoint(
          (rect.left + rect.right)/2,
          (rect.top + rect.bottom)/2
        );
      }

      function pointOnRect(pt, rect) {
      	var rectPt = rectCenter(rect);
      	var slope = (rectPt.y - pt.y) / (rectPt.x - pt.x);

      	if (pt.x <= rectPt.x) { // left side
      		var minXy = slope * (rect.left - pt.x) + pt.y;
      		if (rect.top <= minXy && minXy <= rect.bottom)
            return new DOMPoint(rect.left, minXy);
      	}

      	if (pt.x >= rectPt.x) { // right side
      		var maxXy = slope * (rect.right - pt.x) + pt.y;
      		if (rect.top <= maxXy && maxXy <= rect.bottom)
            return new DOMPoint(rect.right, maxXy);
      	}

      	if (pt.y <= rectPt.y) { // top side
      		var minYx = (rectPt.top - pt.y) / slope + pt.x;
      		if (rect.left <= minYx && minYx <= rect.right)
            return new DOMPoint(minYx, rect.top);
      	}

      	if (pt.y >= rectPt.y) { // bottom side
      		var maxYx = (rect.bottom - pt.y) / slope + pt.x;
      		if (rect.left <= maxYx && maxYx <= rect.right)
            return new DOMPoint(maxYx, rect.bottom);
      	}

        return new DOMPoint(pt.x,pt.y);
      }

      function dragEnterTarget() {
        target.scrollIntoView({behavior: 'instant', block: 'center', inline: 'center'});
        var targetRect = target.getBoundingClientRect();
        var sourceCenter = rectCenter(source.getBoundingClientRect());

        for (var i = 0; i < drop_modifier_keys.length; i++) {
          key = drop_modifier_keys[i];
          if (key == "control"){
            key = "ctrl"
          }
          opts[key + 'Key'] = true;
        }

        var dragEnterEvent = new DragEvent('dragenter', opts);
        target.dispatchEvent(dragEnterEvent);

        // fire 2 dragover events to simulate dragging with a direction
        var entryPoint = pointOnRect(sourceCenter, targetRect)
        var dragOverOpts = Object.assign({clientX: entryPoint.x, clientY: entryPoint.y}, opts);
        var dragOverEvent = new DragEvent('dragover', dragOverOpts);
        target.dispatchEvent(dragOverEvent);
        window.setTimeout(dragOnTarget, step_delay);
      }

      function dragOnTarget() {
        var targetCenter = rectCenter(target.getBoundingClientRect());
        var dragOverOpts = Object.assign({clientX: targetCenter.x + x_offset, clientY: targetCenter.y + y_offset}, opts);
        var dragOverEvent = new DragEvent('dragover', dragOverOpts);
        target.dispatchEvent(dragOverEvent);
        window.setTimeout(dragLeave, step_delay, dragOverEvent.defaultPrevented, dragOverOpts);
      }

      function dragLeave(drop, dragOverOpts) {
        var dragLeaveOptions = Object.assign({}, opts, dragOverOpts);
        var dragLeaveEvent = new DragEvent('dragleave', dragLeaveOptions);
        target.dispatchEvent(dragLeaveEvent);
        if (drop) {
          var dropEvent = new DragEvent('drop', dragLeaveOptions);
          target.dispatchEvent(dropEvent);
        }
        var dragEndEvent = new DragEvent('dragend', dragLeaveOptions);
        source.dispatchEvent(dragEndEvent);
        callback.call(true);
      }

      var source = arguments[0],
          target = arguments[1],
          step_delay = arguments[2],
          drop_modifier_keys = arguments[3],
          x_offset = arguments[4],
          y_offset = arguments[5],
          callback = arguments[6];

      var dt = new DataTransfer();
      var opts = { cancelable: true, bubbles: true, dataTransfer: dt };

      while (source && !source.draggable) {
        source = source.parentElement;
      }

      if (source.tagName == 'A'){
        dt.setData('text/uri-list', source.href);
        dt.setData('text', source.href);
      }
      if (source.tagName == 'IMG'){
        dt.setData('text/uri-list', source.src);
        dt.setData('text', source.src);
      }

      var dragEvent = new DragEvent('dragstart', opts);
      source.dispatchEvent(dragEvent);

      window.setTimeout(dragEnterTarget, step_delay);
    JS

  def html5_drag_by_offset(source, target, x_offset, y_offset)
    page.execute_script(HTML5_DRAG_DROP_SCRIPT, source.native, target.native, 500, [], x_offset, y_offset)
  end
end
