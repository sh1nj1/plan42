if (!window.creativeRowSwipeInitialized) {
  window.creativeRowSwipeInitialized = true;

  document.addEventListener('turbo:load', function() {
    var startX = null;
    var activeRow = null;

    document.addEventListener('touchstart', function(e) {
      activeRow = e.target.closest('.creative-row');
      if (activeRow) {
        startX = e.touches[0].clientX;
      } else {
        startX = null;
      }
    }, { passive: true });

    document.addEventListener('touchend', function(e) {
      if (!activeRow || startX === null) return;
      var diffX = e.changedTouches[0].clientX - startX;
      if (diffX > 50) {
        document.querySelectorAll('.creative-row.show-edit').forEach(function(row) {
          if (row !== activeRow) row.classList.remove('show-edit');
        });
        activeRow.classList.add('show-edit');
      } else if (diffX < -50) {
        activeRow.classList.remove('show-edit');
      }
      activeRow = null;
      startX = null;
    });
  });
}
