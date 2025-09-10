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
  var captionPopup = document.getElementById('caption-popup');
  var captionDisplay = document.getElementById('caption-display');
  var captionInput = document.getElementById('caption-input');
  var closeCaptionBtn = document.getElementById('close-caption-btn');
  var captionCommentId = container.dataset.initialPromptId ? parseInt(container.dataset.initialPromptId, 10) : null;
  var csrfToken = document.querySelector('meta[name="csrf-token"]').getAttribute('content');
  var editingCaption = false;
  var startX = null;
  var slideSubscription = null;
  var lastScrollLeft = 0;

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
        if (captionDisplay) {
          captionDisplay.textContent = data.prompt || '';
        }
        captionCommentId = data.prompt_comment_id || null;
        exitCaptionEdit();
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

  window.addEventListener('keydown', function(e) {
    var key = e.key || e.keyCode;
    if (key === 'ArrowRight' || key === 39) {
      e.preventDefault();
      load(index + 1, true);
    } else if (key === 'ArrowLeft' || key === 37) {
      e.preventDefault();
      load(index - 1, true);
    } else if (key === 's' || key === 83) {
      e.preventDefault();
      toggleCaptionPopup();
    } else if (key === 'e' || key === 69) {
      e.preventDefault();
      openCaptionEditor();
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

  function toggleCaptionPopup() {
    if (!captionPopup) return;
    if (captionPopup.style.display === 'block') {
      captionPopup.style.display = 'none';
      exitCaptionEdit();
    } else {
      if (captionDisplay) {
        captionDisplay.textContent = captionEl ? captionEl.textContent : '';
      }
      captionPopup.style.display = 'block';
    }
  }

  function openCaptionEditor() {
    if (!captionPopup) return;
    if (captionPopup.style.display !== 'block') {
      toggleCaptionPopup();
    }
    if (!captionInput || !captionDisplay) return;
    captionInput.value = captionEl ? captionEl.textContent : '';
    captionInput.style.display = 'block';
    captionDisplay.style.display = 'none';
    captionInput.focus();
    editingCaption = true;
  }

  function exitCaptionEdit() {
    if (!captionInput || !captionDisplay) return;
    captionInput.style.display = 'none';
    captionDisplay.style.display = 'block';
    editingCaption = false;
  }

  function saveCaption() {
    if (!captionInput) return;
    var text = captionInput.value.trim();
    var body = JSON.stringify({ comment: { content: '> ' + text, private: true } });
    var url;
    var method;
    if (captionCommentId) {
      url = '/creatives/' + ids[index] + '/comments/' + captionCommentId;
      method = 'PUT';
    } else {
      url = '/creatives/' + ids[index] + '/comments';
      method = 'POST';
    }
    fetch(url, {
      method: method,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken
      },
      body: body
    })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        captionCommentId = data.id;
        if (captionEl) {
          captionEl.textContent = text;
        }
        if (captionDisplay) {
          captionDisplay.textContent = text;
        }
        exitCaptionEdit();
        captionPopup.style.display = 'none';
      });
  }

  if (captionInput) {
    captionInput.addEventListener('keydown', function(e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        saveCaption();
      }
    });
  }

  if (closeCaptionBtn) {
    closeCaptionBtn.addEventListener('click', function() {
      toggleCaptionPopup();
    });
  }
});
