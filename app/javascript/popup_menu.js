if (!window.popupMenuInitialized) {
  window.popupMenuInitialized = true;

  document.addEventListener('turbo:load', function() {
    document.querySelectorAll('.popup-menu-toggle').forEach(function(btn) {
      var menu = document.getElementById(btn.dataset.menuId);
      if (!menu) return;

      btn.addEventListener('click', function(e) {
        menu.style.display = (menu.style.display === 'block') ? 'none' : 'block';
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
