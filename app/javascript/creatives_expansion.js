if (!window.creativesExpansionInitialized) {
    window.creativesExpansionInitialized = true;

    function expand(childrenDiv, btn) {
        if (childrenDiv.dataset.loaded !== "true") {
            fetch(childrenDiv.dataset.loadUrl)
                .then(r => r.text())
                .then(html => {
                    childrenDiv.innerHTML = html;
                    childrenDiv.dataset.loaded = "true";
                });
        }
        childrenDiv.style.display = "";
        btn.textContent = "▼";
    }
    function collapse(childrenDiv, btn) {
        childrenDiv.style.display = "none";
        btn.textContent = "▶";
    }

    // Toggle children visibility on ▶/▼ button click
    function setupCreativeToggles() {
        console.log("Setting up creative toggles");
        // Get current creative id from path, e.g. /creatives/10 or /creatives
        let match = window.location.pathname.match(/\/creatives\/(\d+)/);
        const currentCreativeId = match ? match[1] : null;
        document.querySelectorAll(".creative-toggle-btn").forEach(function(btn) {
            btn.addEventListener("click", function(e) {
                const creativeId = btn.dataset.creativeId;
                const childrenDiv = document.getElementById(`creative-children-${creativeId}`);
                if (childrenDiv) {
                    const isHidden = childrenDiv.style.display === "none";
                    if (isHidden) {
                        expand(childrenDiv, btn);
                    } else {
                        collapse(childrenDiv, btn);
                    }
                    // Store expansion state in DB, scoped by currentCreativeId and node_id
                    let url = `/creative_expanded_states/toggle`;
                    fetch(url, {
                      method: 'POST',
                      headers: {
                        'Content-Type': 'application/json',
                        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                      },
                      body: JSON.stringify({
                        creative_id: currentCreativeId,
                        node_id: creativeId,
                        expanded: isHidden
                      })
                    });
                }
            });

            // On load, restore state
            const creativeId = btn.dataset.creativeId;
            const childrenDiv = document.getElementById(`creative-children-${creativeId}`);
            if (childrenDiv) {
                if (childrenDiv.dataset.expanded === "true") {
                    expand(childrenDiv, btn);
                } else {
                    collapse(childrenDiv, btn);
                }
            }
        });


        // Toggle Expand/Collapse All Creatives
        var expandBtn = document.getElementById('expand-all-btn');
        if (expandBtn) {
            var expanded = false;
            expandBtn.addEventListener('click', function () {
                var toggles = document.querySelectorAll('.creative-toggle-btn');
                expanded = !expanded;
                toggles.forEach(function(btn) {
                    const creativeId = btn.dataset.creativeId;
                    const childrenDiv = document.getElementById(`creative-children-${creativeId}`);

                    if (childrenDiv && !expanded) {
                        collapse(childrenDiv, btn);
                    } else if (childrenDiv) {
                        expand(childrenDiv, btn);
                    }
                });
                expandBtn.textContent = expanded ? expandBtn.dataset.collapseText : expandBtn.dataset.expandText;
            });
        }
    }

    // XXX: do not initialize Toggles it only do once when page loads or changes, so only use turbo:load
    // document.addEventListener("DOMContentLoaded", setupCreativeToggles);
    document.addEventListener("turbo:load", setupCreativeToggles);
}
