if (!window.isSetPlanModalInitialized) {
    window.isSetPlanModalInitialized = true;

    document.addEventListener('turbo:load', function() {
        var setPlanBtn = document.getElementById('set-plan-btn');
        var modal = document.getElementById('set-plan-modal');
        var selectOneText = modal ? modal.dataset.selectOne : '';
        var selectPlanText = modal ? modal.dataset.selectPlan : '';
        var closeBtn = document.getElementById('close-set-plan-modal');
        var form = document.getElementById('set-plan-form');
        var idsInput = document.getElementById('selected-creative-ids-input');
        var removeBtn = document.getElementById('remove-plan-btn');
        if (setPlanBtn && modal && closeBtn) {
            setPlanBtn.onclick = function() {
                modal.style.display = 'flex';
                document.body.classList.add('no-scroll');
            };
            closeBtn.onclick = function() {
                modal.style.display = 'none';
                document.body.classList.remove('no-scroll');
            };
            modal.onclick = function(e) {
                if (e.target === modal) {
                    modal.style.display = 'none';
                    document.body.classList.remove('no-scroll');
                }
            };
        }
       if (form && idsInput) {
            form.onsubmit = function() {
                var checked = Array.from(document.querySelectorAll('.select-creative-checkbox:checked'));
                var ids = checked.map(cb => cb.value);
                idsInput.value = ids.join(',');
                if (ids.length === 0) {
                    alert(selectOneText);
                    return false;
                }
                return true;
            };
        }
        if (removeBtn && form && idsInput) {
            removeBtn.onclick = function(e) {
                e.preventDefault();
                var checked = Array.from(document.querySelectorAll('.select-creative-checkbox:checked'));
                var ids = checked.map(cb => cb.value);
                idsInput.value = ids.join(',');
                if (ids.length === 0) {
                    alert(selectOneText);
                    return;
                }
                var planId = document.getElementById('plan-id-select').value;
                if (!planId) {
                    alert(selectPlanText);
                    return;
                }
                // Submit via DELETE to creative_plan_path
                var f = document.createElement('form');
                f.method = 'POST';
                f.action = removeBtn.dataset.removePath;
                // CSRF
                var csrf = document.querySelector('meta[name="csrf-token"]');
                if (csrf) {
                    var csrfInput = document.createElement('input');
                    csrfInput.type = 'hidden';
                    csrfInput.name = 'authenticity_token';
                    csrfInput.value = csrf.content;
                    f.appendChild(csrfInput);
                }
                var methodField = document.createElement('input');
                methodField.type = 'hidden';
                methodField.name = '_method';
                methodField.value = 'delete';
                f.appendChild(methodField);
                var idsField = document.createElement('input');
                idsField.type = 'hidden';
                idsField.name = 'creative_ids';
                idsField.value = ids.join(',');
                f.appendChild(idsField);
                var planField = document.createElement('input');
                planField.type = 'hidden';
                planField.name = 'plan_id';
                planField.value = planId;
                f.appendChild(planField);
                document.body.appendChild(f);
                f.submit();
            };
        }
    });
}
