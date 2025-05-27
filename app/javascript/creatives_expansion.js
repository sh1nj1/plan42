if (!window.creativesExpansionInitialized) {
    window.creativesExpansionInitialized = true;

    // Toggle children visibility on ▶/▼ button click
    function setupCreativeToggles() {
        console.log("Setting up creative toggles");
        // Get current creative id from path, e.g. /creatives/10 or /creatives
        let match = window.location.pathname.match(/\/creatives\/(\d+)/);
        const currentCreativeId = match ? match[1] : 'root';
        document.querySelectorAll(".creative-toggle-btn").forEach(function(btn) {
            btn.addEventListener("click", function(e) {
                const creativeId = btn.dataset.creativeId;
                const childrenDiv = document.getElementById(`creative-children-${creativeId}`);
                if (childrenDiv) {
                    const isHidden = childrenDiv.style.display === "none";
                    childrenDiv.style.display = isHidden ? "" : "none";
                    btn.textContent = isHidden ? "▼" : "▶";
                    // Store expansion state in localStorage, scoped by currentCreativeId
                    let allStates = JSON.parse(localStorage.getItem("creativeTreeExpandedByParent") || '{}');
                    let expanded = allStates[currentCreativeId] || {};
                    if (isHidden) {
                        delete expanded[creativeId];
                    } else {
                        expanded[creativeId] = false;
                    }
                    allStates[currentCreativeId] = expanded;
                    localStorage.setItem("creativeTreeExpandedByParent", JSON.stringify(allStates));
                }
            });

            // On load, restore state
            const creativeId = btn.dataset.creativeId;
            const childrenDiv = document.getElementById(`creative-children-${creativeId}`);
            let allStates = JSON.parse(localStorage.getItem("creativeTreeExpandedByParent") || '{}');
            let expanded = allStates[currentCreativeId] || {};
            if (childrenDiv && expanded[creativeId] === undefined) {
                childrenDiv.style.display = "";
                btn.textContent = "▼";
            } else if (childrenDiv) {
                childrenDiv.style.display = "none";
                btn.textContent = "▶";
            }
        });
    }

    // XXX: do not initialize Toggles it only do once when page loads or changes, so only use turbo:load
    // document.addEventListener("DOMContentLoaded", setupCreativeToggles);
    document.addEventListener("turbo:load", setupCreativeToggles);
}