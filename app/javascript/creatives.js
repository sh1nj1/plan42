document.addEventListener('turbo:load', function() {
  const btn = document.getElementById('apply-tags');
  if (!btn) return;
  if (btn.dataset.listenerAttached === 'true') return;
  btn.dataset.listenerAttached = 'true';

  btn.addEventListener('click', function() {
    const checked = Array.from(document.querySelectorAll('.tag-checkbox:checked')).map((cb) => cb.value);
    let url = '/creatives';
    if (checked.length > 0) {
      url += '?tags[]=' + checked.join('&tags[]=');
    }
    window.location.href = url;
  });
});
