document.addEventListener('DOMContentLoaded', function() {
  var container = document.getElementById('slide-view');
  if (!container) return;

  var ids = container.dataset.slideIds.split(',').map(function(id) { return parseInt(id, 10); });
  var index = parseInt(container.dataset.initialIndex || '0', 10);
  var rootId = container.dataset.rootId;
  var contentEl = document.getElementById('slide-content');
  var startX = null;
  var slideSubscription = null;
  var lastScrollLeft = 0;

  function load(idx, broadcast) {
    if (idx < 0 || idx >= ids.length) return;
    index = idx;
    fetch('/creatives/' + ids[index] + '.json')
      .then(function(r) { return r.json(); })
      .then(function(data) {
        contentEl.innerHTML = data.description;
        container.scrollLeft = 0;
        lastScrollLeft = 0;
      });
    if (broadcast && slideSubscription) {
      slideSubscription.perform('change', { index: index });
    }
  }

  if (window.ActionCable && rootId) {
    slideSubscription = ActionCable.createConsumer().subscriptions.create(
      { channel: 'SlideViewChannel', root_id: rootId },
      {
        received: function(data) {
          if (typeof data.index === 'number' && data.index !== index) {
            load(data.index, false);
          }
        }
      }
    );
    // broadcast initial state
    slideSubscription.perform('change', { index: index });
  }

  container.addEventListener('touchstart', function(e) {
    startX = e.touches[0].clientX;
  });

  container.addEventListener('touchend', function(e) {
    if (startX === null) return;
    var dx = e.changedTouches[0].clientX - startX;
    if (Math.abs(dx) > 30) {
      if (dx < 0) {
        load(index + 1, true);
      } else {
        load(index - 1, true);
      }
    }
    startX = null;
  });

  window.addEventListener('keydown', function(e) {
    if (e.key === 'ArrowRight') { load(index + 1, true); }
    if (e.key === 'ArrowLeft') { load(index - 1, true); }
  });

  container.addEventListener('scroll', function() {
    if (container.scrollWidth <= container.clientWidth) return;
    var max = container.scrollWidth - container.clientWidth;
    var left = container.scrollLeft;
    if (left === 0 && lastScrollLeft > 0) {
      load(index - 1, true);
    } else if (left >= max && lastScrollLeft < max) {
      load(index + 1, true);
    }
    lastScrollLeft = left;
  });
});
