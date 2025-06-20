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
          requestAnimationFrame(function() {
            var rect = menu.getBoundingClientRect();
            var shift = 0;
            if (rect.right > window.innerWidth) {
              shift = rect.right - window.innerWidth + 4;
              menu.style.transform = 'translateX(-' + shift + 'px)';
            } else if (rect.left < 0) {
              shift = -rect.left + 4;
              menu.style.transform = 'translateX(' + shift + 'px)';
            }
          });
        }
        e.stopPropagation();
      });

      document.addEventListener('click', function(e) {
        if (menu.style.display === 'block' && !menu.contains(e.target) && e.target !== btn) {
          menu.style.display = 'none';
        }
      });

      /* Close menu on button click */
      menu.addEventListener('click', function(e) {
        if (e.target.closest('button[type="button"]')) {
          menu.style.display = 'none';
        }
      });
    });
  });
}
