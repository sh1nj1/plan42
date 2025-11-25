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

    function position() {
      var rect = textarea.getBoundingClientRect();
      var parentRect = menu.offsetParent.getBoundingClientRect();
      menu.style.top = (rect.bottom - parentRect.top) + 'px';
      menu.style.left = (rect.left - parentRect.left) + 'px';
    }

    function hide() {
      menu.style.display = 'none';
    }

    function insert(user) {
      var pos = textarea.selectionStart;
        var before = textarea.value.slice(0, pos).replace(/@[^@\s]*$/, '@' + user.name + ': ');
      textarea.value = before + textarea.value.slice(pos);
    }

    function show(users) {
      list.innerHTML = '';
      users.forEach(function (u) {
        var li = document.createElement('li');
        li.className = 'mention-item';
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
      } else {
        hide();
      }
    }

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
