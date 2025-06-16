if (!window.isSelectModeInitialized) {
    window.isSelectModeInitialized = true;

    document.addEventListener('turbo:load', function() {
        var selectBtn = document.getElementById('select-creative-btn');
        if (!selectBtn) return;
        selectBtn.addEventListener('click', function() {
            Array.from(document.getElementsByClassName("select-creative-checkbox")).forEach(function(element) {
                element.style.display = element.style.display === 'none' ? '' : 'none';
            });
            Array.from(document.getElementsByClassName("add-creative-btn")).forEach(function(element) {
                element.style.display = element.style.display === 'none' ? '' : 'none';
            });
            Array.from(document.getElementsByClassName("creative-tags")).forEach(function(element) {
                element.style.display = element.style.display === 'none' ? '' : 'none';
            });
            Array.from(document.getElementsByClassName("comments-btn")).forEach(function(element) {
                element.style.display = element.style.display === 'none' ? '' : 'none';
            });
            const selectAllBtn = document.getElementById('select-all-creatives')
            if (selectAllBtn) {
                selectAllBtn.style.display = selectAllBtn.style.display === 'none' ? '' : 'none';
            }
            const setPlanBtn = document.getElementById('set-plan-btn');
            if (setPlanBtn) {
                setPlanBtn.style.display = setPlanBtn.style.display === 'none' ? '' : 'none';
            }
            selectBtn.textContent = (selectBtn.textContent === selectBtn.dataset.cancelText) ? selectBtn.dataset.selectText : selectBtn.dataset.cancelText;
        });
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
