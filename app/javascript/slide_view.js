document.addEventListener('DOMContentLoaded', function() {
  var container = document.getElementById('slide-view');
  if (!container) return;

  var ids = container.dataset.slideIds.split(',').map(function(id) { return parseInt(id, 10); });
  var index = parseInt(container.dataset.initialIndex || '0', 10);
  var rootId = container.dataset.rootId;
  var contentEl = document.getElementById('slide-content');
  var swipeArea = document.getElementById('slide-swipe');
  var counterEl = document.getElementById('slide-counter');
  var linkEl = document.getElementById('slide-goto');
  var captionEl = document.getElementById('slide-caption');
  var timerEl = document.getElementById('slide-timer');
  var startX = null;
  var slideSubscription = null;
  var lastScrollLeft = 0;
  var timerStart = null;
  var timerInterval = null;

  if (index > 0) {
    load(index, false);
  } else {
    updateUrl(index);
  }

  function updateUrl(idx) {
    var url = new URL(window.location);
    url.searchParams.set('slide', idx);
    history.replaceState(null, '', url);
  }

  function load(idx, broadcast) {
    if (idx < 0 || idx >= ids.length) return;
    index = idx;
    updateUrl(index);
    if (counterEl) {
      counterEl.textContent = (index + 1) + ' / ' + ids.length;
    }
    if (linkEl) {
      linkEl.href = '/creatives/' + ids[index];
    }
    var url = '/creatives/' + ids[index] + '.json';
    if (rootId) {
      url += '?root_id=' + rootId;
    }
    fetch(url)
      .then(function(r) { return r.json(); })
      .then(function(data) {
        var depth = data.depth || 1;
        var tag = 'div';
        if (depth === 1) {
          tag = 'h1';
        } else if (depth === 2) {
          tag = 'h2';
        } else if (depth === 3) {
          tag = 'h3';
        }
        contentEl.innerHTML = '';
        var el = document.createElement(tag);
        el.innerHTML = data.description;
        contentEl.appendChild(el);
        if (captionEl) {
          captionEl.textContent = data.prompt || '';
        }
        requestAnimationFrame(function() {
          container.scrollLeft = 0;
          container.scrollTop = 0;
          lastScrollLeft = 0;
        });
      });
    if (broadcast && slideSubscription) {
      slideSubscription.perform('change', { index: index });
    }
  }

  function updateTimer() {
    if (!timerEl || timerStart === null) return;
    var elapsedSeconds = Math.floor((Date.now() - timerStart) / 1000);
    var minutes = Math.floor(elapsedSeconds / 60);
    var seconds = elapsedSeconds % 60;
    var formattedMinutes = minutes.toString().padStart(2, '0');
    var formattedSeconds = seconds.toString().padStart(2, '0');
    timerEl.textContent = formattedMinutes + ':' + formattedSeconds;
  }

  function startTimer() {
    if (!timerEl) return;
    timerStart = Date.now();
    updateTimer();
    if (timerInterval) {
      clearInterval(timerInterval);
    }
    timerInterval = setInterval(updateTimer, 1000);
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

  if (swipeArea) {
    swipeArea.addEventListener('touchstart', function(e) {
      startX = e.touches[0].clientX;
    });

    swipeArea.addEventListener('touchend', function(e) {
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
  }

  if (counterEl) {
    counterEl.textContent = (index + 1) + ' / ' + ids.length;
  }
  if (linkEl) {
    linkEl.href = '/creatives/' + ids[index];
  }

  startTimer();

  window.addEventListener('keydown', function(e) {
    var key = e.key || e.keyCode;
    if (key === 'ArrowRight' || key === 39) {
      e.preventDefault();
      load(index + 1, true);
    } else if (key === 'ArrowLeft' || key === 37) {
      e.preventDefault();
      load(index - 1, true);
    }
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
