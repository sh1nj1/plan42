import { Turbo } from "@hotwired/turbo-rails"

// Register custom actions on both the imported Turbo and the global window.Turbo
// to handle cases where the bundled Turbo instance differs from the runtime one.
function registerStreamAction(name, handler) {
    Turbo.StreamActions[name] = handler
    if (window.Turbo && window.Turbo.StreamActions && window.Turbo.StreamActions !== Turbo.StreamActions) {
        window.Turbo.StreamActions[name] = handler
    }
}

// Creative tree sync: directly updates rows from broadcast data (no HTTP fetch needed)
registerStreamAction("refresh_creative_tree", function () {
    const rawData = this.getAttribute("data")
    if (!rawData) return

    let payload
    try {
        payload = JSON.parse(rawData)
    } catch (e) {
        console.warn("[CreativeSync] Failed to parse broadcast data", e)
        return
    }

    const { action, creative } = payload
    if (!creative || !creative.id) return

    console.log("[CreativeSync] Received", action, "for creative", creative.id)

    if (action === "destroyed") {
        handleCreativeDestroyed(creative)
    } else {
        handleCreativeUpserted(creative, action)
    }
})

function handleCreativeDestroyed(creative) {
    const rows = document.querySelectorAll(`creative-tree-row[creative-id="${creative.id}"]`)
    rows.forEach(row => {
        // Remove the row's parent .creative-tree container
        const tree = row.closest('.creative-tree') || row
        tree.remove()
    })
}

function handleCreativeUpserted(creative, action) {
    const rows = document.querySelectorAll(`creative-tree-row[creative-id="${creative.id}"]`)

    if (rows.length === 0 && action === "created") {
        // New creative — need a tree refetch to properly insert it
        // (we don't have enough data to construct a full row client-side)
        dispatchRefetchEvent(creative)
        return
    }

    // Update all matching rows (title row + tree row if both exist)
    rows.forEach(row => applyCreativeData(row, creative))

    // If progress changed, parent rows need updating too — dispatch a targeted refetch
    // only for the children tree, not the whole page
    if (action === "updated") {
        dispatchRefetchEvent(creative)
    }
}

function applyCreativeData(row, creative) {
    // Update display HTML
    if (creative.description_html != null) {
        row.descriptionHtml = creative.description_html
    }

    // Update editor cache (descriptionRawHtml) so next edit loads fresh data
    if (creative.description_raw_html != null) {
        row.dataset.descriptionRawHtml = creative.description_raw_html
    }

    // Update progress value (the visual progress_html will be refreshed by tree refetch)
    if (creative.progress != null) {
        row.dataset.progressValue = String(creative.progress)
    }

    // Update origin
    if (creative.origin_id != null) {
        row.dataset.originId = String(creative.origin_id)
    }

    // Update has_children
    if (creative.has_children != null) {
        row.hasChildren = creative.has_children
    }
}

function dispatchRefetchEvent(creative) {
    document.dispatchEvent(new CustomEvent('creative-sync:refetch', {
        detail: {
            creativeId: creative.id,
            parentId: creative.parent_id,
            action: 'sync'
        },
        bubbles: true
    }))
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
