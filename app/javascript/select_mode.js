if (!window.isSelectModeInitialized) {
    window.isSelectModeInitialized = true;
    let selectModeActive = false;
    let dragging = false;
    let dragMode = 'toggle';

    function applySelection(row) {
        var cb = row.querySelector('.select-creative-checkbox');
        if (!cb) return;
        if (dragMode === 'remove') {
            cb.checked = false;
            row.classList.remove('selected');
        } else if (dragMode === 'add') {
            cb.checked = true;
            row.classList.add('selected');
        } else {
            cb.checked = !cb.checked;
            row.classList.toggle('selected');
        }
    }

    function clearAllSelection() {
        document.querySelectorAll('.select-creative-checkbox').forEach(function(cb) {
            cb.checked = false;
            var r = cb.closest('.creative-row');
            if (r) r.classList.remove('selected');
        });
    }

    function attachRowHandlers() {
        document.querySelectorAll('.creative-row').forEach(function(row) {
            if (row.dataset.selectHandlerAttached) return;
            row.dataset.selectHandlerAttached = 'true';
            row.addEventListener('mousedown', function(e) {
                if (!selectModeActive) return;
                dragging = true;
                dragMode = e.altKey ? 'remove' : (e.shiftKey ? 'add' : 'toggle');
                applySelection(row);
                e.preventDefault();
            });
            row.addEventListener('mouseenter', function() {
                if (dragging && selectModeActive) {
                    applySelection(row);
                }
            });
            var cb = row.querySelector('.select-creative-checkbox');
            if (cb) {
                cb.addEventListener('change', function() {
                    if (cb.checked) {
                        row.classList.add('selected');
                    } else {
                        row.classList.remove('selected');
                    }
                });
            }
        });
        document.addEventListener('mouseup', function() { dragging = false; });
    }

    document.addEventListener('turbo:load', function() {
        attachRowHandlers();
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
            selectModeActive = !selectModeActive;
            if (selectModeActive) {
                attachRowHandlers();
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
        attachRowHandlers();
    });
}
