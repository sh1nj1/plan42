
if (!window.isSelectModeInitialized) {
    window.isSelectModeInitialized = true;

    document.addEventListener('turbo:load', function() {
        var selectBtn = document.getElementById('select-creative-btn');
        if (!selectBtn) return;
        selectBtn.addEventListener('click', function() {
            var url = new URL(window.location.href);
            if (url.searchParams.get('select_mode')) {
                url.searchParams.delete('select_mode');
            } else {
                url.searchParams.set('select_mode', '1');
            }
            window.location.href = url.toString();
        });
        // Change button text if in select mode
        if (window.location.search.includes('select_mode')) {
            selectBtn.textContent = '<%= t("app.cancel_select") %>';
        }
    });
    document.addEventListener('turbo:load', function() {
        var selectAll = document.getElementById('select-all-creatives');
        if (selectAll) {
            selectAll.addEventListener('change', function() {
                var boxes = document.querySelectorAll('.select-creative-checkbox');
                boxes.forEach(function(cb) { cb.checked = selectAll.checked; });
            });
        }
    });
}