let initialized = false;

document.addEventListener('turbo:load', function() {
  if (initialized) return;
  initialized = true;

  const btn = document.getElementById('apply-tags');
  if (!btn) return;
  btn.addEventListener('click', function() {
    const checked = Array.from(document.querySelectorAll('.tag-checkbox:checked')).map((cb) => cb.value);
    let url = '/creatives';
    if (checked.length > 0) {
      url += '?tags[]=' + checked.join('&tags[]=');
    }
    window.location.href = url;
  });
});
