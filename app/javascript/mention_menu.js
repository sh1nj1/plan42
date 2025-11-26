let mentionMenuInitialized = false;

if (!mentionMenuInitialized) {
  mentionMenuInitialized = true;

  document.addEventListener('turbo:load', function () {
    var textarea = document.querySelector('#new-comment-form textarea');
    var menu = document.getElementById('mention-menu');
    var popup = document.getElementById('comments-popup');
    if (!textarea || !menu) return;

    var list = menu.querySelector('.mention-results');
    var fetchTimer;
    var activeIndex = -1;

    function isVisible() {
      return menu.style.display === 'block';
    }

    function position() {
      var rect = textarea.getBoundingClientRect();
      var parentRect = menu.offsetParent.getBoundingClientRect();
      menu.style.top = (rect.bottom - parentRect.top) + 'px';
      menu.style.left = (rect.left - parentRect.left) + 'px';
    }

    function hide() {
      menu.style.display = 'none';
      activeIndex = -1;
      updateActive();
    }

    function insert(user) {
      var pos = textarea.selectionStart;
      var before = textarea.value.slice(0, pos).replace(/@[^@\s]*$/, '@' + user.name + ': ');
      textarea.value = before + textarea.value.slice(pos);
      textarea.setSelectionRange(before.length, before.length);
    }

    function updateActive() {
      var items = list.children;
      Array.from(items).forEach(function (item, index) {
        item.classList.toggle('active', index === activeIndex);
      });
    }

    function setActiveIndex(index) {
      var items = list.children;
      if (items.length === 0) return;
      if (index < 0) {
        activeIndex = items.length - 1;
      } else {
        activeIndex = index % items.length;
      }
      updateActive();
      var activeItem = items[activeIndex];
      if (activeItem && activeItem.scrollIntoView) {
        activeItem.scrollIntoView({ block: 'nearest' });
      }
    }

    function selectActive() {
      if (activeIndex < 0) return;
      var item = list.children[activeIndex];
      if (item) item.click();
    }

    function show(users) {
      list.innerHTML = '';
      activeIndex = users.length > 0 ? 0 : -1;
      users.forEach(function (u, index) {
        var li = document.createElement('li');
        li.className = 'mention-item' + (index === activeIndex ? ' active' : '');
        li.innerHTML = '<img src="' + u.avatar_url + '" width="20" height="20" class="avatar" /> ' + u.name;
        li.addEventListener('click', function () {
          insert(u);
          hide();
          textarea.focus();
        });
        list.appendChild(li);
      });
      if (users.length > 0) {
        menu.style.display = 'block';
        position();
        updateActive();
      } else {
        hide();
      }
    }

    textarea.addEventListener('keydown', function (event) {
      if (!isVisible()) return;

      var key = event.key;
      var isCtrl = event.ctrlKey || event.metaKey;
      if (key === 'Tab' || key === 'Enter') {
        event.preventDefault();
        selectActive();
      } else if (key === 'ArrowDown' || (isCtrl && key.toLowerCase() === 'n')) {
        event.preventDefault();
        setActiveIndex(activeIndex + 1);
      } else if (key === 'ArrowUp' || (isCtrl && key.toLowerCase() === 'p')) {
        event.preventDefault();
        setActiveIndex(activeIndex - 1);
      }
    });

    textarea.addEventListener('input', function () {
      var pos = textarea.selectionStart;
      var before = textarea.value.slice(0, pos);
      var m = before.match(/@([^\s@]*)$/);
      if (m) {
        var q = m[1];
        if (q.length === 0) { hide(); return; }
        clearTimeout(fetchTimer);
        fetchTimer = setTimeout(function () {
          var url = new URL('/users/search', window.location.origin);
          url.searchParams.set('q', q);
          if (popup && popup.dataset.creativeId) {
            url.searchParams.set('creative_id', popup.dataset.creativeId);
          }
          fetch(url, { headers: { 'Accept': 'application/json' } })
            .then(function (r) { return r.ok ? r.json() : []; })
            .then(show)
            .catch(function () { });
        }, 200);
      } else {
        hide();
      }
    });

    document.addEventListener('click', function (e) {
      if (!menu.contains(e.target) && e.target !== textarea) {
        hide();
      }
    });
  });
}
