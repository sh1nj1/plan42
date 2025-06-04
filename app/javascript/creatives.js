if (!window.creativesInitialized) {
    window.creativesInitialized = true;

    document.addEventListener('turbo:load', function () {
        var btn = document.getElementById('apply-tags');
        if (!btn) return;
        btn.addEventListener('click', function () {
            var checked = Array.from(document.querySelectorAll('.tag-checkbox:checked')).map(cb => cb.value);
            var url = '/creatives';
            if (checked.length > 0) {
                url += '?tags[]=' + checked.join('&tags[]=');
            }
            window.location.href = url;
        });
    });
}