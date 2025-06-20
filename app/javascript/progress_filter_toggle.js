if (!window.progressFilterToggleInitialized) {
  window.progressFilterToggleInitialized = true;

  document.addEventListener('turbo:load', function() {
    document.querySelectorAll('.progress-filter-btn').forEach(function(btn) {
      btn.addEventListener('click', function() {
        var filter = btn.dataset.filter;
        var url = new URL(window.location.href);

        if (filter === 'comment') {
          if (url.searchParams.get('comment') === 'true') {
            url.searchParams.delete('comment');
          } else {
            url.searchParams.set('comment', 'true');
          }
        } else {
          url.searchParams.delete('min_progress');
          url.searchParams.delete('max_progress');
          if (filter === 'complete') {
            url.searchParams.set('min_progress', '1');
            url.searchParams.set('max_progress', '1');
          } else if (filter === 'incomplete') {
            url.searchParams.set('min_progress', '0');
            url.searchParams.set('max_progress', '0.99');
          }
        }

        window.location.href =
          url.pathname + (url.searchParams.toString() ? '?' + url.searchParams.toString() : '');
      });
    });
  });
}
