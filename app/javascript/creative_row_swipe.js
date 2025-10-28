let initialized = false;

document.addEventListener('turbo:load', function() {
  if (initialized) return;
  initialized = true;

  let startX = null;
  let activeRow = null;
  let allEditVisible = false;

  const toggleBtn = document.getElementById('toggle-edit-btn');
  if (toggleBtn) {
    toggleBtn.addEventListener('click', function() {
      allEditVisible = !allEditVisible;
      document.querySelectorAll('.creative-row').forEach(function(row) {
        row.classList.toggle('show-edit', allEditVisible);
      });
    });
  }

  document.addEventListener('touchstart', function(event) {
    if (allEditVisible) return;
    activeRow = event.target.closest('.creative-row');
    startX = activeRow ? event.touches[0].clientX : null;
  }, { passive: true });

  document.addEventListener('touchend', function(event) {
    if (allEditVisible || !activeRow || startX === null) return;
    const diffX = event.changedTouches[0].clientX - startX;
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
