if (!window.creativeRowSwipeInitialized) {
  window.creativeRowSwipeInitialized = true;

  document.addEventListener('turbo:load', function() {
    var startX = null;
    var activeRow = null;
    var allEditVisible = false;

    var toggleBtn = document.getElementById('toggle-edit-btn');
    if (toggleBtn) {
      toggleBtn.addEventListener('click', function() {
        allEditVisible = !allEditVisible;
        document.querySelectorAll('.creative-row').forEach(function(row) {
          if (allEditVisible) {
            row.classList.add('show-edit');
          } else {
            row.classList.remove('show-edit');
          }
        });
      });
    }

    document.addEventListener('touchstart', function(e) {
      if (allEditVisible) return;
      activeRow = e.target.closest('.creative-row');
      if (activeRow) {
        startX = e.touches[0].clientX;
      } else {
        startX = null;
      }
    }, { passive: true });

    document.addEventListener('touchend', function(e) {
      if (allEditVisible || !activeRow || startX === null) return;
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
