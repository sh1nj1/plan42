import { Controller } from "@hotwired/stimulus"

/**
 * Manages agent-level context creatives in the AI agent edit form.
 * Reuses the same chip-based UI pattern as comments/contexts_controller.
 * All changes are persisted immediately via server API.
 * - Adding: auto-grants read permission if needed; blocks if no_access.
 * - Removing/reordering: updates agent_conf directly.
 */
export default class extends Controller {
    static targets = ["list"]
    static values = {
        userId: Number,
        initialData: { type: Array, default: [] }
    }

    static ICON_CONTEXT_LINK = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>'

    connect() {
        this.contexts = (this.initialDataValue || []).map(d => ({
            id: d.id,
            description: d.description || `Creative #${d.id}`
        }))
        this.draggingContextId = null
        this._render()
    }

    _render() {
        if (!this.hasListTarget) return

        const dragActions = 'dragstart->agent-contexts#handleDragStart dragend->agent-contexts#handleDragEnd'
        const reorderActions = 'dragover->agent-contexts#handleReorderDragOver dragleave->agent-contexts#handleReorderDragLeave drop->agent-contexts#handleReorderDrop'

        let html = ''

        if (this.contexts.length === 0) {
            html += `<span class="text-muted small">${this.listTarget.dataset.emptyLabel || 'No context creatives configured.'}</span>`
        }

        this.contexts.forEach(ctx => {
            html += `<span class="context-chip" draggable="true"
                          data-action="${dragActions} ${reorderActions}"
                          data-context-id="${ctx.id}">
                        ${this.constructor.ICON_CONTEXT_LINK} ${this._escapeHtml(ctx.description)}
                        <button class="navigate-context-btn" data-action="click->agent-contexts#navigateToContext" data-context-id="${ctx.id}" title="Go to creative">\u2192</button>
                        <button class="delete-context-btn" data-action="click->agent-contexts#removeContext" data-context-id="${ctx.id}">&times;</button>
                     </span>`
        })

        html += `<button class="add-context-btn" data-action="click->agent-contexts#addContext" type="button">+</button>`

        this.listTarget.innerHTML = html
    }

    addContext() {
        const linkController = window.Stimulus?.getControllerForElementAndIdentifier(
            document.querySelector('[data-controller~="link-creative"]'),
            'link-creative'
        )

        if (!linkController) {
            console.error("link-creative controller not found")
            return
        }

        const addBtn = this.listTarget.querySelector('.add-context-btn')
        const rect = addBtn?.getBoundingClientRect() || { top: 200, left: 200, bottom: 230, right: 230 }

        linkController.open(rect, (selectedCreative) => {
            this._addCreativeViaApi(selectedCreative.id)
        })
    }

    async _addCreativeViaApi(creativeId) {
        const id = parseInt(creativeId)
        if (this.contexts.some(c => c.id === id)) return

        try {
            const response = await this._fetch(
                `/users/${this.userIdValue}/add_agent_context_creative`,
                'POST',
                { creative_id: id }
            )

            if (response.ok) {
                const data = await response.json()
                this.contexts.push({ id: data.id, description: data.description })
                this._render()
            } else {
                const data = await response.json().catch(() => ({}))
                this._showError(data.error || 'Failed to add creative')
            }
        } catch (e) {
            console.error('Error adding agent context creative', e)
        }
    }

    async removeContext(event) {
        event.stopPropagation()
        const contextId = parseInt(event.currentTarget.dataset.contextId)

        try {
            const response = await this._fetch(
                `/users/${this.userIdValue}/remove_agent_context_creative`,
                'DELETE',
                { creative_id: contextId }
            )

            if (response.ok) {
                this.contexts = this.contexts.filter(c => c.id !== contextId)
                this._render()
            }
        } catch (e) {
            console.error('Error removing agent context creative', e)
        }
    }

    navigateToContext(event) {
        event.stopPropagation()
        const contextId = event.currentTarget.dataset.contextId
        if (contextId) {
            window.open(`/creatives/${contextId}`, '_blank')
        }
    }

    // --- Drag & Drop for reordering ---
    handleDragStart(event) {
        const chipEl = event.currentTarget
        const contextId = chipEl.dataset.contextId
        if (!contextId) { event.preventDefault(); return }

        this.draggingContextId = contextId
        event.dataTransfer.setData('application/x-agent-context-id', contextId)
        event.dataTransfer.effectAllowed = 'move'

        requestAnimationFrame(() => {
            chipEl.classList.add('context-dragging')
        })
    }

    handleDragEnd(event) {
        this.draggingContextId = null
        event.currentTarget.classList.remove('context-dragging')
        this.listTarget.querySelectorAll('.context-chip').forEach(el => {
            el.classList.remove('context-drag-over-left', 'context-drag-over-right')
        })
    }

    handleReorderDragOver(event) {
        if (!event.dataTransfer.types.includes('application/x-agent-context-id')) return
        if (!this.draggingContextId) return

        const targetEl = event.currentTarget
        const targetId = targetEl.dataset.contextId
        if (!targetId || targetId === this.draggingContextId) return

        event.preventDefault()
        event.dataTransfer.dropEffect = 'move'

        const rect = targetEl.getBoundingClientRect()
        const midpoint = rect.left + rect.width / 2
        const isLeft = event.clientX < midpoint

        targetEl.classList.toggle('context-drag-over-left', isLeft)
        targetEl.classList.toggle('context-drag-over-right', !isLeft)
    }

    handleReorderDragLeave(event) {
        event.currentTarget.classList.remove('context-drag-over-left', 'context-drag-over-right')
    }

    async handleReorderDrop(event) {
        const targetEl = event.currentTarget
        targetEl.classList.remove('context-drag-over-left', 'context-drag-over-right')

        if (!event.dataTransfer.types.includes('application/x-agent-context-id')) return

        event.preventDefault()
        event.stopPropagation()

        const draggedId = parseInt(event.dataTransfer.getData('application/x-agent-context-id'))
        const targetId = parseInt(targetEl.dataset.contextId)

        if (!draggedId || !targetId || draggedId === targetId) return

        const draggedIndex = this.contexts.findIndex(c => c.id === draggedId)
        const targetIndex = this.contexts.findIndex(c => c.id === targetId)
        if (draggedIndex === -1 || targetIndex === -1) return

        const rect = targetEl.getBoundingClientRect()
        const midpoint = rect.left + rect.width / 2
        const insertBefore = event.clientX < midpoint

        const [dragged] = this.contexts.splice(draggedIndex, 1)
        let newIndex = this.contexts.findIndex(c => c.id === targetId)
        if (!insertBefore) newIndex += 1
        this.contexts.splice(newIndex, 0, dragged)

        this._render()

        // Persist new order
        await this._fetch(
            `/users/${this.userIdValue}/reorder_agent_context_creatives`,
            'PATCH',
            { creative_ids: this.contexts.map(c => c.id) }
        )
    }

    // --- External drop (creative from tree) ---
    handleExternalDragOver(event) {
        if (event.dataTransfer.types.includes('application/x-collavre-creative')) {
            event.preventDefault()
            event.dataTransfer.dropEffect = 'move'
            this.listTarget.classList.add('context-drop-active')
        }
    }

    handleExternalDragLeave(event) {
        if (!this.listTarget.contains(event.relatedTarget)) {
            this.listTarget.classList.remove('context-drop-active')
        }
    }

    async handleExternalDrop(event) {
        if (!event.dataTransfer.types.includes('application/x-collavre-creative')) return

        event.preventDefault()
        event.stopPropagation()
        this.listTarget.classList.remove('context-drop-active')

        const rawData = event.dataTransfer.getData('application/x-collavre-creative')
        if (!rawData) return

        try {
            const parsed = JSON.parse(rawData)
            const creativeId = parseInt(parsed.creativeId)
            if (creativeId) {
                await this._addCreativeViaApi(creativeId)
            }
        } catch (e) { /* ignore */ }
    }

    // --- Helpers ---
    async _fetch(url, method, body) {
        return fetch(url, {
            method,
            headers: {
                'Content-Type': 'application/json',
                'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''
            },
            body: JSON.stringify(body)
        })
    }

    _showError(message) {
        // Brief inline error display
        const errorEl = document.createElement('div')
        errorEl.className = 'agent-context-error'
        errorEl.textContent = message
        errorEl.style.cssText = 'color: var(--color-error, #dc3545); font-size: 0.85em; margin-top: 4px;'
        this.listTarget.parentNode.appendChild(errorEl)
        setTimeout(() => errorEl.remove(), 4000)
    }

    _escapeHtml(text) {
        const div = document.createElement('div')
        div.textContent = text
        return div.innerHTML
    }
}
