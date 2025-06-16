if (!window.userMenuInitialized) {
  window.userMenuInitialized = true;

  document.addEventListener('turbo:load', function() {
    var btn = document.getElementById('user-menu-btn');
    var menu = document.getElementById('user-menu');
    if (!btn || !menu) return;

    function toggle() {
      if (menu.style.display === 'block') {
        menu.style.display = 'none';
      } else {
        var rect = btn.getBoundingClientRect();
        menu.style.top = (rect.bottom + window.scrollY + 4) + 'px';
        menu.style.right = (window.innerWidth - rect.right) + 'px';
        menu.style.left = '';
        menu.style.display = 'block';
      }
    }

    btn.addEventListener('click', function() {
      toggle();
    });

    document.addEventListener('click', function(e) {
      if (menu.style.display === 'block' && !menu.contains(e.target) && !btn.contains(e.target)) {
        menu.style.display = 'none';
      }
    });
  });
}
