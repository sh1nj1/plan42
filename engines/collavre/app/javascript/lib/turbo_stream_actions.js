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

    // Use linked_id if present (shared creative: receiver sees linked copy, not origin)
    const effectiveId = creative.linked_id || creative.id

    // Override id with effectiveId for DOM lookups
    const effectiveCreative = { ...creative, id: effectiveId, origin_id: creative.id }

    switch (action) {
        case "created":
            handleCreated(effectiveCreative)
            break
        case "updated":
            handleUpdated(effectiveCreative)
            break
        case "destroyed":
            handleDestroyed(effectiveCreative)
            break
    }

    // Update ancestor progress for all actions
    updateAncestorProgress(creative.ancestors)
})

function handleCreated(creative) {
    const parentId = creative.parent_id

    // Duplicate broadcast protection
    if (document.querySelector(`creative-tree-row[creative-id="${creative.id}"]`)) {
        return
    }

    const treeContainer = document.getElementById('creatives')
    if (!treeContainer) {
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
    }
    // If no targetContainer found, the creative is relevant but we can't determine
    // the exact insertion point — it will appear on next page load.
}

function insertAtCorrectPosition(newRow, creative, container) {
    const prevSiblingId = creative.previous_sibling_id
    const afterId = creative.after_id  // from user's add action in CreateService
    const sequence = creative.sequence

    const siblingRows = Array.from(container.querySelectorAll(':scope > creative-tree-row'))

    // Helper: insert after a row (accounting for its children container)
    const treeRoot = document.getElementById('creatives')
    function insertAfterRow(targetId, label) {
        const row = container.querySelector(`:scope > creative-tree-row[creative-id="${targetId}"]`)
            || (treeRoot && treeRoot.querySelector(`creative-tree-row[creative-id="${targetId}"]`))
        if (!row) return false
        const childContainer = document.getElementById(`creative-children-${targetId}`)
        const ref = childContainer || row
        ref.insertAdjacentElement('afterend', newRow)
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
                return
            }
        }
    }

    // Strategy 4: first child (no previous sibling)
    if (!prevSiblingId && !afterId && (sequence === 0 || sequence == null)) {
        if (siblingRows.length > 0) {
            container.insertBefore(newRow, siblingRows[0])
            return
        }
    }

    // Fallback: append at end
    container.appendChild(newRow)
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

function findRowsForCreative(creativeId, originId) {
    // 1. Normal tree rows by attribute
    const rows = Array.from(document.querySelectorAll(`creative-tree-row[creative-id="${creativeId}"]`))
    if (rows.length > 0) return rows

    // 1b. Try origin_id if different (linked creative: DOM may have origin ID)
    if (originId && String(originId) !== String(creativeId)) {
        const originRows = Array.from(document.querySelectorAll(`creative-tree-row[creative-id="${originId}"]`))
        if (originRows.length > 0) return originRows
    }

    // 2. Title row checks
    const titleRow = document.querySelector('creative-tree-row[is-title]')
    if (titleRow) {
        // 2a. Title row has creative-id attribute (e.g. /creatives?id=X page)
        const titleCreativeId = titleRow.getAttribute('creative-id')
        if (titleCreativeId && (String(titleCreativeId) === String(creativeId) ||
            (originId && String(titleCreativeId) === String(originId)))) {
            return [titleRow]
        }
        // 2b. URL param check
        const urlId = new URLSearchParams(window.location.search).get('id')
        if (urlId && (String(urlId) === String(creativeId) ||
            (originId && String(urlId) === String(originId)))) {
            return [titleRow]
        }
        // 2c. Top-level page: if any tree row has parent-id matching creativeId or originId,
        //     then creativeId is the root of this tree = title row
        if (!titleCreativeId) {
            const childOfTarget = document.querySelector(`creative-tree-row[parent-id="${creativeId}"]`) ||
                (originId ? document.querySelector(`creative-tree-row[parent-id="${originId}"]`) : null)
            if (childOfTarget) {
                return [titleRow]
            }
        }
    }
    return rows
}

function handleUpdated(creative) {
    // Notify popup controllers about creative data changes (e.g. trigger state)
    // Must fire before the early return — popup may be open for a creative
    // that isn't visible in the current tree view.
    document.dispatchEvent(new CustomEvent('creative:updated', {
        detail: { creativeId: creative.id, originId: creative.origin_id }
    }))

    const rows = findRowsForCreative(creative.id, creative.origin_id)
    if (rows.length === 0) return

    // Find currently editing creative ID to skip it
    const editForm = document.querySelector('#inline-edit-form-element')
    const editingId = editForm?.dataset?.creativeId

    rows.forEach(row => {
        if (String(creative.id) === String(editingId)) {
            if (creative.inline_editor_payload) {
                row.dataset.pendingSyncData = JSON.stringify(creative)
            }
            return
        }
        applyRowProperties(row, creative)
    })
}

function handleDestroyed(creative) {
    const rows = findRowsForCreative(creative.id, creative.origin_id)

    if (rows.length === 0) return // Row not visible on this page

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

}

function updateProgressForRow(row, progress, progressText) {
    if (progress == null) return
    const pct = Math.round(progress * 100)
    const cssClass = pct >= 100 ? 'creative-progress-complete' : 'creative-progress-incomplete'
    // progressText from server: completion mark string, empty string (=complete but no mark), or null
    const displayText = progressText != null ? (progressText || '\u00a0\u00a0') : `${pct}%`

    row.dataset.progressValue = String(progress)

    if (row.progressHtml) {
        // Try regex replacement on existing progress HTML (preserves chat buttons etc.)
        const regex = /(<span[^>]*class="creative-progress-(?:in)?complete"[^>]*>)[^<]*(<\/span>)/
        const updated = row.progressHtml.replace(regex, `$1${displayText}$2`)
        if (updated !== row.progressHtml) {
            // Also update ONLY the first progress class (not chat buttons etc.)
            const classUpdated = updated.replace(
                /class="creative-progress-(?:in)?complete"/,
                `class="${cssClass}"`
            )
            row.progressHtml = classUpdated
            row.dataset.progressHtml = classUpdated
        }
        // If regex didn't match, do NOT create fresh HTML — preserve existing progressHtml
        // (it contains chat buttons, comment badges, etc.)
    }
}

function updateAncestorProgress(ancestors) {
    if (!Array.isArray(ancestors)) return
    ancestors.forEach(anc => {
        // findRowsForCreative already handles origin_id fallback for linked creatives
        const rows = findRowsForCreative(anc.id, anc.origin_id)
        if (rows[0]) updateProgressForRow(rows[0], anc.progress, anc.progress_text)
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
