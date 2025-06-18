if (!window.progressFilterToggleInitialized) {
  window.progressFilterToggleInitialized = true;

  document.addEventListener('turbo:load', function() {
    document.querySelectorAll('.progress-filter-toggle').forEach(function(btn) {
      btn.addEventListener('click', function() {
        var state = btn.dataset.state;
        var states = ['complete', 'incomplete', 'all'];
        var nextState = states[(states.indexOf(state) + 1) % states.length];
        var url = new URL(window.location.href);
        url.searchParams.delete('min_progress');
        url.searchParams.delete('max_progress');
      if (nextState === 'complete') {
        url.searchParams.set('min_progress', '1');
        url.searchParams.set('max_progress', '1');
      } else if (nextState === 'incomplete') {
        url.searchParams.set('min_progress', '0');
        url.searchParams.set('max_progress', '0.99');
      }
        window.location.href = url.pathname + (url.searchParams.toString() ? '?' + url.searchParams.toString() : '');
      });
    });
  });
}
