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
    // Find the parent's children container to insert the new row
    const parentId = creative.parent_id
    if (!parentId) return

    // Check if parent row exists in the current view
    const parentRow = document.querySelector(`creative-tree-row[creative-id="${parentId}"]`)
    if (!parentRow) return // Parent not visible — nothing to do

    // Find or create the children container
    let childrenContainer = document.getElementById(`creative-children-${parentId}`)

    if (!childrenContainer) {
        // Create a new children container after the parent row
        childrenContainer = document.createElement('div')
        childrenContainer.className = 'creative-children'
        childrenContainer.id = `creative-children-${parentId}`
        childrenContainer.dataset.expanded = 'true'
        childrenContainer.dataset.loaded = 'true'
        parentRow.insertAdjacentElement('afterend', childrenContainer)
    }

    // Make sure children container is visible
    childrenContainer.style.display = ''
    childrenContainer.dataset.expanded = 'true'

    // Check if the row already exists (duplicate broadcast protection)
    if (document.querySelector(`creative-tree-row[creative-id="${creative.id}"]`)) return

    // Create the new row using tree_renderer's createRow
    const newRow = createRow(creative)
    childrenContainer.appendChild(newRow)

    // Update parent's has-children state
    parentRow.hasChildren = true
    parentRow.setAttribute('has-children', '')

    // Expand parent if not already
    if (!parentRow.expanded) {
        parentRow.expanded = true
        parentRow.setAttribute('expanded', '')
    }

    console.log("[CreativeSync] Inserted new row for creative", creative.id, "under parent", parentId)
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
