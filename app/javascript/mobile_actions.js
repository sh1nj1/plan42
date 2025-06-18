if (!window.mobileActionsInitialized) {
  window.mobileActionsInitialized = true;

  document.addEventListener('turbo:load', function () {
    document.querySelectorAll('[data-click-target]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var target = document.getElementById(btn.dataset.clickTarget);
        if (target) {
          target.click();
        }
        var menu = btn.closest('.popup-menu');
        if (menu) {
          menu.style.display = 'none';
        }
      });
    });
  });
}
