import { Turbo } from "@hotwired/turbo-rails"

// Register custom actions on both the imported Turbo and the global window.Turbo
// to handle cases where the bundled Turbo instance differs from the runtime one.
function registerStreamAction(name, handler) {
    Turbo.StreamActions[name] = handler
    if (window.Turbo && window.Turbo.StreamActions && window.Turbo.StreamActions !== Turbo.StreamActions) {
        window.Turbo.StreamActions[name] = handler
    }
}

// Creative tree refresh: triggered when a shared creative is created/updated/destroyed
registerStreamAction("refresh_creative_tree", function () {
    const creativeId = this.getAttribute("creative-id")
    const action = this.getAttribute("change-action")
    console.log("[Turbo] refresh_creative_tree", { creativeId, action })

    // Update title row if the changed creative matches it.
    // Non-title rows are handled by tree refetch (debouncedLoad) which
    // includes inline_editor_payload with fresh description_raw_html.
    if (creativeId) {
        const titleRow = document.querySelector('creative-tree-row[is-title]')
        if (titleRow && String(titleRow.getAttribute('creative-id')) === String(creativeId)) {
            refreshCreativeRow(titleRow, creativeId)
        }
    }

    // Dispatch event for any listening tree controller to refetch children
    document.dispatchEvent(new CustomEvent('creative-sync:refetch', {
        detail: { creativeId: creativeId ? parseInt(creativeId, 10) : null, action },
        bubbles: true
    }))
})

async function refreshCreativeRow(row, creativeId) {
    try {
        const response = await fetch(`/creatives/${creativeId}.json`, {
            headers: { Accept: 'application/json' }
        })
        if (!response.ok) return
        const data = await response.json()
        // Update visible description (show.json returns 'description' as HTML)
        if (data.description) {
            row.descriptionHtml = data.description
        }
        // Update raw HTML cache so inline editor loads fresh data
        if (data.description_raw_html != null) {
            row.dataset.descriptionRawHtml = data.description_raw_html
        }
        if (data.progress_html) {
            row.progressHtml = data.progress_html
            row.dataset.progressHtml = data.progress_html
        }
        if (data.progress != null) {
            row.dataset.progressValue = String(data.progress)
        }
        if (data.origin_id != null) {
            row.dataset.originId = String(data.origin_id)
        }
        console.log("[Turbo] refreshed creative row", creativeId)
    } catch (e) {
        console.warn("[Turbo] failed to refresh title row", e)
    }
}

registerStreamAction("update_reactions", function () {
    const targetId = this.getAttribute("target")
    const dataJSON = this.getAttribute("data")

    console.log("[Turbo] update_reactions action received", { targetId, dataJSON })

    if (!targetId || !dataJSON) {
        console.warn("[Turbo] update_reactions missing target or data")
        return
    }

    try {
        const data = JSON.parse(dataJSON)
        const element = document.getElementById(targetId)

        if (element) {
            // Find the stimulus controller instance using the global Stimulus application
            const controller = window.Stimulus?.getControllerForElementAndIdentifier(element, "comment")
            if (controller && typeof controller.updateReactionsUI === 'function') {
                console.log("[Turbo] calling updateReactionsUI", data)
                controller.updateReactionsUI(data)
            } else {
                console.warn("[Turbo] comment controller not found", { element, controller })
            }
        } else {
            console.warn("[Turbo] target element not found", targetId)
        }
    } catch (e) {
        console.error("Failed to process update_reactions stream action", e)
    }
})
