if (!window.creativesExpansionInitialized) {
    window.creativesExpansionInitialized = true;

    let allExpanded = false;
    let currentCreativeId = null;

    function computeCurrentCreativeId() {
        let match = window.location.pathname.match(/\/creatives\/(\d+)/);
        let id = match ? match[1] : null;
        if (!id) {
            const params = new URLSearchParams(window.location.search);
            id = params.get('id');
        }
        return id;
    }

    function saveExpansionState(creativeId, expanded) {
        if (!creativeId) return;
        if (currentCreativeId === null) currentCreativeId = computeCurrentCreativeId();

        const contextId = currentCreativeId ?? null;

        fetch('/creative_expanded_states/toggle', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
            },
            body: JSON.stringify({
                creative_id: contextId,
                node_id: creativeId,
                expanded: expanded
            })
        });
    }

    function toggleButtonFor(row) {
        return row.querySelector('.creative-toggle-btn');
    }

    function childrenContainerFor(row) {
        const creativeId = row.creativeId || row.getAttribute('creative-id');
        if (!creativeId) return null;
        return document.getElementById(`creative-children-${creativeId}`);
    }

    function ensureLoaded(row, childrenDiv) {
        if (!childrenDiv) {
            row.hasChildren = false;
            return Promise.resolve(false);
        }
        if (childrenDiv.dataset.loaded === 'true') {
            const has = !!childrenDiv.querySelector('creative-tree-row');
            row.hasChildren = has;
            return Promise.resolve(has);
        }

        const url = childrenDiv.dataset.loadUrl;
        if (!url) {
            row.hasChildren = false;
            return Promise.resolve(false);
        }

        return fetch(url)
            .then(r => r.text())
            .then(html => {
                childrenDiv.innerHTML = html;
                childrenDiv.dataset.loaded = 'true';
                initializeRows(childrenDiv);
                if (window.attachCreativeRowEditorButtons) window.attachCreativeRowEditorButtons();
                if (window.attachCommentButtons) window.attachCommentButtons();
                const has = !!childrenDiv.querySelector('creative-tree-row');
                row.hasChildren = has;
                return has;
            });
    }

    function expandRow(row, { persist = true } = {}) {
        const creativeId = row.creativeId || row.getAttribute('creative-id');
        const childrenDiv = childrenContainerFor(row);
        ensureLoaded(row, childrenDiv).then(hasChildren => {
            if (!hasChildren || !childrenDiv) {
                collapseRow(row, { persist: false });
                return;
            }
            childrenDiv.style.display = '';
            childrenDiv.dataset.expanded = 'true';
            row.expanded = true;
            if (persist) saveExpansionState(creativeId, true);
        });
    }

    function collapseRow(row, { persist = true } = {}) {
        const creativeId = row.creativeId || row.getAttribute('creative-id');
        const childrenDiv = childrenContainerFor(row);
        if (childrenDiv) {
            childrenDiv.style.display = 'none';
            childrenDiv.dataset.expanded = 'false';
        }
        row.expanded = false;
        if (persist) saveExpansionState(creativeId, false);
    }

    function toggleRow(row) {
        if (row.expanded) {
            collapseRow(row);
        } else {
            expandRow(row);
        }
    }

    function initializeRows(container) {
        container.querySelectorAll('creative-tree-row').forEach(row => {
            syncInitialState(row);
        });
    }

    function syncInitialState(row) {
        const childrenDiv = childrenContainerFor(row);
        const shouldExpand = allExpanded || row.expanded || (childrenDiv && childrenDiv.dataset.expanded === 'true');
        if (shouldExpand && row.hasChildren) {
            expandRow(row, { persist: false });
        } else {
            collapseRow(row, { persist: false });
        }
    }

    document.addEventListener('creative-toggle-click', function(event) {
        const row = event.detail?.component;
        if (!row) return;
        toggleRow(row);
    });

    function setupCreativeToggles() {
        currentCreativeId = computeCurrentCreativeId();
        allExpanded = false;

        const expandBtn = document.getElementById('expand-all-btn');
        if (expandBtn) {
            expandBtn.ariaLabel = expandBtn.dataset.expandText;
            if (expandBtn.firstChild) expandBtn.firstChild.textContent = '▼';
        }

        initializeRows(document);

        if (expandBtn) {
            expandBtn.addEventListener('click', function () {
                const rows = document.querySelectorAll('creative-tree-row');
                allExpanded = !allExpanded;
                rows.forEach(row => {
                    if (allExpanded) {
                        expandRow(row, { persist: false });
                    } else {
                        collapseRow(row, { persist: false });
                    }
                });
                expandBtn.ariaLabel = allExpanded ? expandBtn.dataset.collapseText : expandBtn.dataset.expandText;
                if (expandBtn.firstChild) {
                    expandBtn.firstChild.textContent = allExpanded ? '▶' : '▼';
                }
            });
        }
    }

    document.addEventListener('turbo:load', setupCreativeToggles);
}
