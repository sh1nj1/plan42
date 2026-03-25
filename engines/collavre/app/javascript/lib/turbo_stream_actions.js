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

    // Strategy: find where to insert the new row
    // 1. Parent is in tree as regular row → insert into its children container
    // 2. Parent is the title row (page root) → insert into #creatives directly
    // 3. Parent is not visible but its children ARE in #creatives → insert into #creatives
    // 4. Fallback: reload the tree (safest option)

    const targetContainer = findTargetContainer(parentId, treeContainer)

    if (targetContainer) {
        targetContainer.style.display = ''
        if (targetContainer.dataset) targetContainer.dataset.expanded = 'true'

        const newRow = createRow(creative)
        insertAtCorrectPosition(newRow, creative, targetContainer)
        console.log("[CreativeSync] Inserted row for creative", creative.id)
    } else {
        // Fallback: trigger tree reload — the creative is relevant to this page
        // (we received the broadcast) but we can't determine exact insertion point
        console.log("[CreativeSync] Fallback: reloading tree for created creative", creative.id)
        document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
    }
}

function insertAtCorrectPosition(newRow, creative, container) {
    const prevSiblingId = creative.previous_sibling_id
    const afterId = creative.after_id  // from user's add action in CreateService
    const sequence = creative.sequence

    const siblingRows = Array.from(container.querySelectorAll(':scope > creative-tree-row'))
    console.log("[CreativeSync] insertAtCorrectPosition", {
        id: creative.id, afterId, prevSiblingId, sequence,
        siblingCount: siblingRows.length,
        siblingIds: siblingRows.map(r => r.getAttribute('creative-id'))
    })

    // Helper: insert after a row (accounting for its children container)
    function insertAfterRow(targetId, label) {
        const row = container.querySelector(`:scope > creative-tree-row[creative-id="${targetId}"]`)
            || document.querySelector(`creative-tree-row[creative-id="${targetId}"]`)
        if (!row) return false
        const childContainer = document.getElementById(`creative-children-${targetId}`)
        const ref = childContainer || row
        ref.insertAdjacentElement('afterend', newRow)
        console.log(`[CreativeSync] Inserted after ${label}`, targetId)
        return true
    }

    // Strategy 1: after_id — the creative user clicked "add after" (most reliable)
    if (afterId && insertAfterRow(afterId, 'after_id')) return

    // Strategy 2: previous_sibling_id — computed from DB after resequencing
    if (prevSiblingId && insertAfterRow(prevSiblingId, 'prev_sibling')) return

    // Strategy 3: sequence comparison among visible siblings
    if (sequence != null) {
        for (const row of siblingRows) {
            const rowSeq = parseInt(row.getAttribute('sequence'), 10)
            if (!isNaN(rowSeq) && rowSeq > sequence) {
                container.insertBefore(newRow, row)
                console.log("[CreativeSync] Inserted before row with sequence", rowSeq)
                return
            }
        }
    }

    // Strategy 4: first child (no previous sibling)
    if (!prevSiblingId && !afterId && (sequence === 0 || sequence == null)) {
        if (siblingRows.length > 0) {
            container.insertBefore(newRow, siblingRows[0])
            console.log("[CreativeSync] Inserted at beginning")
            return
        }
    }

    // Fallback: append at end
    container.appendChild(newRow)
    console.log("[CreativeSync] Appended at end (fallback)")
}

function findTargetContainer(parentId, treeContainer) {
    if (!parentId) {
        // No parent → top-level creative, insert into main container
        return treeContainer
    }

    // 1. Check if parent exists as a regular tree row
    const parentRow = document.querySelector(`creative-tree-row[creative-id="${parentId}"]`)
    if (parentRow) {
        if (parentRow.hasAttribute('is-title')) {
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
        parentRow.hasChildren = true
        parentRow.setAttribute('has-children', '')
        if (!parentRow.expanded) {
            parentRow.expanded = true
            parentRow.setAttribute('expanded', '')
        }
        return container
    }

    // 2. Check if parent is the page root (title row)
    const rootId = treeContainer.dataset?.creativesSyncRootIdValue
    if (rootId && String(parentId) === String(rootId)) {
        return treeContainer
    }

    // 3. Check title row's creative-id attribute
    const titleRow = document.querySelector('creative-tree-row[is-title]')
    const titleCreativeId = titleRow?.getAttribute('creative-id')
    if (titleCreativeId && String(parentId) === String(titleCreativeId)) {
        return treeContainer
    }

    // 4. Check if any siblings of the new creative are already in #creatives
    //    (parent's other children are direct children of #creatives → top-level page)
    const sibling = treeContainer.querySelector(`creative-tree-row[parent-id="${parentId}"]`)
    if (sibling) {
        return treeContainer
    }

    // 5. If the tree container has ANY rows, this broadcast is relevant to this page
    //    Return null to trigger fallback tree reload
    const anyRow = treeContainer.querySelector('creative-tree-row')
    if (anyRow) {
        return null  // will trigger refetch fallback
    }

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

    if (rows.length === 0) {
        // Row not found — might be on a page where it's displayed differently
        // Trigger tree reload as fallback
        console.log("[CreativeSync] Destroyed creative", creative.id, "not found in tree, reloading")
        document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
        return
    }

    rows.forEach(row => {
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
            ancRow.dataset.progressValue = String(Math.round(anc.progress))
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
