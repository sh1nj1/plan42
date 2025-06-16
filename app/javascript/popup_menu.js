if (!window.popupMenuInitialized) {
  window.popupMenuInitialized = true;

  document.addEventListener('turbo:load', function() {
    document.querySelectorAll('.popup-menu-toggle').forEach(function(btn) {
      var menu = document.getElementById(btn.dataset.menuId);
      if (!menu) return;

      btn.addEventListener('click', function(e) {
        if (menu.style.display === 'block') {
          menu.style.display = 'none';
        } else {
          menu.style.display = 'block';
          menu.style.transform = '';
          var rect = menu.getBoundingClientRect();
          var overflow = rect.right - window.innerWidth;
          if (overflow > 0) {
            menu.style.transform = 'translateX(-' + (overflow + 4) + 'px)';
          }
        }
        e.stopPropagation();
      });

      document.addEventListener('click', function(e) {
        if (menu.style.display === 'block' && !menu.contains(e.target) && e.target !== btn) {
          menu.style.display = 'none';
        }
      });
    });
  });
}
