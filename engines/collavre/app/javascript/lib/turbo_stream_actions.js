import { Turbo } from "@hotwired/turbo-rails"
import { createRow, applyRowProperties } from "../creatives/tree_renderer"

// Register custom actions on both the imported Turbo and the global window.Turbo
function registerStreamAction(name, handler) {
    Turbo.StreamActions[name] = handler
    if (window.Turbo && window.Turbo.StreamActions && window.Turbo.StreamActions !== Turbo.StreamActions) {
        window.Turbo.StreamActions[name] = handler
    }
}

// ─── Creative tree sync ──────────────────────────────────────────────
// Receives full creative data via WebSocket and applies changes directly
// to the DOM — zero HTTP fetch for any CRUD operation.

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

    switch (action) {
        case "created":
            handleCreated(creative)
            break
        case "updated":
            handleUpdated(creative)
            break
        case "destroyed":
            handleDestroyed(creative)
            break
    }

    // Update ancestor progress for all actions
    updateAncestorProgress(creative.ancestors)
})

function handleCreated(creative) {
    const parentId = creative.parent_id
    console.log("[CreativeSync] handleCreated", { id: creative.id, parentId, level: creative.level })

    if (!parentId) {
        console.log("[CreativeSync] No parent_id, skipping")
        return
    }

    // Duplicate broadcast protection
    if (document.querySelector(`creative-tree-row[creative-id="${creative.id}"]`)) {
        console.log("[CreativeSync] Row already exists, skipping")
        return
    }

    const treeContainer = document.getElementById('creatives')
    if (!treeContainer) {
        console.log("[CreativeSync] Tree container #creatives not found")
        return
    }

    // Determine where to insert the new row
    const targetContainer = findTargetContainer(parentId, treeContainer)
    if (!targetContainer) {
        console.log("[CreativeSync] Could not find target container for parent", parentId)
        return
    }

    // Make sure container is visible
    targetContainer.style.display = ''
    if (targetContainer.dataset) targetContainer.dataset.expanded = 'true'

    const newRow = createRow(creative)
    targetContainer.appendChild(newRow)
    console.log("[CreativeSync] Inserted row for creative", creative.id, "into", targetContainer.id || 'tree container')
}

function findTargetContainer(parentId, treeContainer) {
    const parentRow = document.querySelector(`creative-tree-row[creative-id="${parentId}"]`)

    if (parentRow) {
        if (parentRow.hasAttribute('is-title')) {
            // Title row's children go directly into #creatives
            return treeContainer
        }
        // Regular row — use or create children container
        let container = document.getElementById(`creative-children-${parentId}`)
        if (!container) {
            container = document.createElement('div')
            container.className = 'creative-children'
            container.id = `creative-children-${parentId}`
            container.dataset.expanded = 'true'
            container.dataset.loaded = 'true'
            parentRow.insertAdjacentElement('afterend', container)
        }
        // Update parent state
        parentRow.hasChildren = true
        parentRow.setAttribute('has-children', '')
        if (!parentRow.expanded) {
            parentRow.expanded = true
            parentRow.setAttribute('expanded', '')
        }
        return container
    }

    // Parent row not found as a tree row. Check if the parent IS the page root.
    // The page root's ID is stored on the tree container (or title row without creative-id).
    const rootId = treeContainer.dataset?.creativesSyncRootIdValue
    if (rootId && String(parentId) === String(rootId)) {
        // Parent is the current page's root creative — children go into #creatives
        return treeContainer
    }

    // Fallback: check title row's creative-id
    const titleRow = document.querySelector('creative-tree-row[is-title]')
    const titleCreativeId = titleRow?.getAttribute('creative-id')
    if (titleCreativeId && String(parentId) === String(titleCreativeId)) {
        return treeContainer
    }

    // If parent is not visible on this page, the creative belongs in a subtree
    // that's not currently expanded. Nothing to do.
    console.log("[CreativeSync] Parent", parentId, "not visible on this page (rootId:", rootId, ")")
    return null
}

function handleUpdated(creative) {
    const rows = document.querySelectorAll(`creative-tree-row[creative-id="${creative.id}"]`)
    if (rows.length === 0) return

    // Find currently editing creative ID to skip it
    const editForm = document.querySelector('#inline-edit-form-element')
    const editingId = editForm?.dataset?.creativeId

    rows.forEach(row => {
        if (String(creative.id) === String(editingId)) {
            // Don't touch the row being edited — it would close the editor.
            // Cache the latest data so when the editor closes, it can be applied.
            if (creative.inline_editor_payload) {
                row.dataset.pendingSyncData = JSON.stringify(creative)
            }
            return
        }
        applyRowProperties(row, creative)
    })

    console.log("[CreativeSync] Updated", rows.length, "row(s) for creative", creative.id)
}

function handleDestroyed(creative) {
    const rows = document.querySelectorAll(`creative-tree-row[creative-id="${creative.id}"]`)
    if (rows.length === 0) return

    rows.forEach(row => {
        // Also remove the associated children container
        const childrenContainer = document.getElementById(`creative-children-${creative.id}`)
        if (childrenContainer) childrenContainer.remove()
        row.remove()
    })

    // Update parent's has-children state if no more children
    if (creative.parent_id) {
        const parentChildrenContainer = document.getElementById(`creative-children-${creative.parent_id}`)
        if (parentChildrenContainer) {
            const remaining = parentChildrenContainer.querySelectorAll('creative-tree-row')
            if (remaining.length === 0) {
                const parentRow = document.querySelector(`creative-tree-row[creative-id="${creative.parent_id}"]`)
                if (parentRow) {
                    parentRow.hasChildren = false
                    parentRow.removeAttribute('has-children')
                }
                parentChildrenContainer.remove()
            }
        }
    }

    console.log("[CreativeSync] Removed row(s) for creative", creative.id)
}

function updateAncestorProgress(ancestors) {
    if (!Array.isArray(ancestors)) return
    ancestors.forEach(anc => {
        const ancRow = document.querySelector(`creative-tree-row[creative-id="${anc.id}"]`)
        if (ancRow && anc.progress != null) {
            ancRow.dataset.progressValue = String(anc.progress)
        }
    })
}

// ─── Reactions sync ──────────────────────────────────────────────────

registerStreamAction("update_reactions", function () {
    const targetId = this.getAttribute("target")
    const dataJSON = this.getAttribute("data")

    if (!targetId || !dataJSON) return

    try {
        const data = JSON.parse(dataJSON)
        const element = document.getElementById(targetId)
        if (element) {
            const controller = window.Stimulus?.getControllerForElementAndIdentifier(element, "comment")
            if (controller && typeof controller.updateReactionsUI === 'function') {
                controller.updateReactionsUI(data)
            }
        }
    } catch (e) {
        console.error("Failed to process update_reactions stream action", e)
    }
})
