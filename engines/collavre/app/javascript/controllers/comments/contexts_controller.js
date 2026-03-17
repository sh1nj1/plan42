import { Controller } from "@hotwired/stimulus"

const CREATIVE_MIME_TYPE = 'application/x-collavre-creative'

export default class extends Controller {
    static targets = ["list", "toggleButton"]

    static ICON_CONTEXT_LINK = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>'
    static ICON_CONTEXT_PIN = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="17" x2="12" y2="22"/><path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"/></svg>'

    connect() {
        this.contexts = []
        this.canManage = false
        this.draggingContextId = null
        this.listVisible = false
        // External drop zone handlers are now Stimulus actions on the list target
    }

    get creativeId() {
        return this.element.closest('#comments-popup')?.dataset?.creativeId
    }

    async onPopupOpened({ creativeId }) {
        this._hasBeenManuallyToggled = false
        this.listVisible = false
        this._updateListVisibility()
        await this.loadContexts()
        this._bindPopupDragDetection()
    }

    onPopupClosed() {
        this.contexts = []
        this.canManage = false
        if (this.hasListTarget) {
            this.listTarget.innerHTML = ''
        }
        this._unbindPopupDragDetection()
    }

    async loadContexts() {
        const creativeId = this.creativeId
        if (!creativeId) return

        try {
            const response = await fetch(`/creatives/${creativeId}/contexts`)
            if (response.ok) {
                const data = await response.json()
                this.contexts = data.contexts || []
                this.canManage = data.can_manage || false
                this._selfContextDisabled = data.disabled_self_context || false
                this.renderContexts()
            }
        } catch (e) {
            console.error("Failed to load contexts", e)
        }
    }

    toggleVisibility() {
        this._hasBeenManuallyToggled = true
        this.listVisible = !this.listVisible
        this._updateListVisibility()
    }

    _updateListVisibility() {
        if (!this.hasListTarget) return
        this.listTarget.style.display = this.listVisible ? '' : 'none'

        // Update toggle button active state
        if (this.hasToggleButtonTarget) {
            this.toggleButtonTarget.classList.toggle('context-toggle-active', this.listVisible)
        }
    }

    _updateToggleButton() {
        if (!this.hasToggleButtonTarget) return

        const hasLinkedContexts = this.contexts.length > 0
        // Always show button (self-context toggle is always available)
        this.toggleButtonTarget.style.display = ''

        // Show badge count when hidden
        if (!this.listVisible) {
            const activeLinked = this.contexts.filter(c => !c.disabled).length
            const selfActive = this.selfContextDisabled ? 0 : 1
            const total = activeLinked + selfActive
            this.toggleButtonTarget.innerHTML = `${this.constructor.ICON_CONTEXT_LINK} ${total}`
        } else {
            this.toggleButtonTarget.innerHTML = this.constructor.ICON_CONTEXT_LINK
        }

        // Auto-show if linked contexts exist, otherwise keep hidden
        if (hasLinkedContexts && !this._hasBeenManuallyToggled) {
            this.listVisible = true
            this._updateListVisibility()
        } else if (!hasLinkedContexts && !this.canManage && !this._hasBeenManuallyToggled) {
            this.listVisible = false
            this._updateListVisibility()
        }
    }

    renderContexts() {
        if (!this.hasListTarget) return

        this._updateToggleButton()
        // Drop zone is handled by Stimulus data-action on the list element

        const dragActions = this.canManage
            ? 'dragstart->comments--contexts#handleDragStart dragend->comments--contexts#handleDragEnd'
            : ''
        const reorderActions = this.canManage
            ? 'dragover->comments--contexts#handleReorderDragOver dragleave->comments--contexts#handleReorderDragLeave drop->comments--contexts#handleReorderDrop'
            : ''

        let html = ''

        // Current creative self-context toggle (always first)
        const selfDisabled = this.selfContextDisabled
        const selfClass = selfDisabled ? 'context-disabled' : ''
        const selfLabel = this._escapeHtml(this.currentCreativeSnippet || 'Self')
        html += `<span class="context-chip context-self ${selfClass}"
                      data-action="click->comments--contexts#toggleSelfContext"
                      title="${this.selfContextLabel}">
                    ${this.constructor.ICON_CONTEXT_PIN} ${selfLabel}
                 </span>`

        this.contexts.forEach(ctx => {
            const disabledClass = ctx.disabled ? 'context-disabled' : ''
            const inheritedClass = ctx.inherited ? 'context-inherited' : ''
            const draggable = this.canManage && !ctx.inherited ? 'draggable="true"' : ''

            html += `<span class="context-chip ${disabledClass} ${inheritedClass}" ${draggable}
                          data-action="click->comments--contexts#toggleContext ${dragActions} ${reorderActions}"
                          data-context-id="${ctx.id}"
                          title="${ctx.inherited ? this.inheritedLabel : ''}">
                        ${this.constructor.ICON_CONTEXT_LINK} ${this._escapeHtml(ctx.description)}`

            html += `<button class="navigate-context-btn" data-action="click->comments--contexts#navigateToContext" data-context-id="${ctx.id}" title="${this.navigateLabel}">\u2192</button>`

            if (this.canManage && !ctx.inherited) {
                html += `<button class="delete-context-btn" data-action="click->comments--contexts#removeContext" data-context-id="${ctx.id}">&times;</button>`
            }

            html += `</span>`
        })

        if (this.canManage) {
            html += `<button class="add-context-btn" data-action="click->comments--contexts#addContext">+</button>`
        }

        this.listTarget.innerHTML = html
    }

    get inheritedLabel() {
        return this.listTarget.dataset.inheritedLabel || 'Inherited from parent'
    }

    get selfContextLabel() {
        return this.listTarget.dataset.selfContextLabel || 'Current creative context'
    }

    get navigateLabel() {
        return this.listTarget.dataset.navigateLabel || 'Go to creative'
    }

    get currentCreativeSnippet() {
        const popup = this.element.closest('#comments-popup')
        return popup?.querySelector('#comments-popup-title')?.textContent?.trim()
    }

    get selfContextDisabled() {
        return this._selfContextDisabled || false
    }

    toggleSelfContext(event) {
        this._selfContextDisabled = !this._selfContextDisabled
        this.renderContexts()
        this._saveSelfContextState()
    }

    async _saveSelfContextState() {
        await this._patchContexts({ disabled_self_context: this._selfContextDisabled })
    }

    navigateToContext(event) {
        event.stopPropagation()
        const contextId = event.currentTarget.dataset.contextId
        if (!contextId) return
        window.location.href = `/creatives/${contextId}`
    }

    toggleContext(event) {
        if (event.target.closest('.delete-context-btn') || event.target.closest('.navigate-context-btn')) return

        const contextId = parseInt(event.currentTarget.dataset.contextId)
        if (!contextId) return

        const ctx = this.contexts.find(c => c.id === contextId)
        if (!ctx) return

        ctx.disabled = !ctx.disabled
        this.renderContexts()
        this._saveDisabledState()
    }

    async removeContext(event) {
        event.stopPropagation()
        const contextId = parseInt(event.currentTarget.dataset.contextId)
        if (!contextId) return

        const ownContexts = this.contexts.filter(c => !c.inherited)
        const newIds = ownContexts.filter(c => c.id !== contextId).map(c => c.id)

        await this._updateContextIds(newIds)
        await this.loadContexts()
    }

    addContext() {
        // Use the existing link-creative modal
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
            this._addContextId(selectedCreative.id)
        })
    }

    async _addContextId(creativeId) {
        // Prevent adding self as context
        const selfId = parseInt(this.creativeId)
        if (creativeId === selfId) return

        const ownContexts = this.contexts.filter(c => !c.inherited)
        const existingIds = ownContexts.map(c => c.id)

        if (existingIds.includes(creativeId)) return
        // Also check inherited
        if (this.contexts.some(c => c.id === creativeId)) return

        const newIds = [...existingIds, creativeId]
        await this._updateContextIds(newIds)
        await this.loadContexts()
    }

    // --- Drag & Drop for reordering ---
    handleDragStart(event) {
        const chipEl = event.currentTarget
        const contextId = chipEl.dataset.contextId
        if (!contextId) { event.preventDefault(); return }

        this.draggingContextId = contextId
        event.dataTransfer.setData('application/x-context-id', contextId)
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
        if (!event.dataTransfer.types.includes('application/x-context-id')) return
        if (!this.draggingContextId) return

        const targetEl = event.currentTarget
        const targetId = targetEl.dataset.contextId
        if (!targetId || targetId === this.draggingContextId) return
        // Don't allow reorder onto inherited chips
        const ctx = this.contexts.find(c => String(c.id) === targetId)
        if (ctx?.inherited) return

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

        // If this is a creative drag (not a context reorder), let it bubble to the list handler
        if (!event.dataTransfer.types.includes('application/x-context-id')) return

        event.preventDefault()
        event.stopPropagation()

        const draggedId = parseInt(event.dataTransfer.getData('application/x-context-id'))
        const targetId = parseInt(targetEl.dataset.contextId)

        if (!draggedId || !targetId || draggedId === targetId) return

        const ownContexts = this.contexts.filter(c => !c.inherited)
        const ids = ownContexts.map(c => c.id)

        const draggedIndex = ids.indexOf(draggedId)
        const targetIndex = ids.indexOf(targetId)
        if (draggedIndex === -1 || targetIndex === -1) return

        // Determine drop position
        const rect = targetEl.getBoundingClientRect()
        const midpoint = rect.left + rect.width / 2
        const insertBefore = event.clientX < midpoint

        ids.splice(draggedIndex, 1)
        let newIndex = ids.indexOf(targetId)
        if (!insertBefore) newIndex += 1
        ids.splice(newIndex, 0, draggedId)

        await this._updateContextIds(ids)
        await this.loadContexts()
    }

    // --- API calls ---
    async _updateContextIds(ids) {
        await this._patchContexts({ context_ids: ids })
    }

    async _saveDisabledState() {
        const disabledIds = this.contexts.filter(c => c.disabled).map(c => c.id)
        await this._patchContexts({ disabled_context_ids: disabledIds })
    }

    async _patchContexts(params) {
        const creativeId = this.creativeId
        if (!creativeId) return

        try {
            const response = await fetch(`/creatives/${creativeId}/update_contexts`, {
                method: 'PATCH',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''
                },
                body: JSON.stringify(params)
            })

            if (!response.ok) {
                console.error('Failed to update contexts', params)
            }
        } catch (e) {
            console.error('Error updating contexts', e)
        }
    }

    // --- Auto-show context list when dragging creative over popup ---
    _bindPopupDragDetection() {
        const popup = this.element.closest('#comments-popup')
        if (!popup) return
        // Unbind any existing handlers first to prevent accumulation across opens
        this._unbindPopupDragDetection()
        this._popupEl = popup
        this._boundPopupDragOver = this._handlePopupDragOver.bind(this)
        this._boundPopupDragLeave = this._handlePopupDragLeave.bind(this)
        this._boundPopupDrop = this.handleExternalDrop.bind(this)
        popup.addEventListener('dragover', this._boundPopupDragOver)
        popup.addEventListener('dragleave', this._boundPopupDragLeave)
        popup.addEventListener('drop', this._boundPopupDrop)
    }

    _unbindPopupDragDetection() {
        if (!this._popupEl) return
        this._popupEl.removeEventListener('dragover', this._boundPopupDragOver)
        this._popupEl.removeEventListener('dragleave', this._boundPopupDragLeave)
        this._popupEl.removeEventListener('drop', this._boundPopupDrop)
        this._popupEl = null
    }

    _handlePopupDragOver(event) {
        if (this._isInternalReorder(event)) return
        if (!this._isCreativeDrag(event)) return
        if (!this.canManage) return

        // Must preventDefault to allow drop on the popup
        event.preventDefault()
        event.dataTransfer.dropEffect = 'move'

        if (!this.listVisible) {
            // Auto-show context list when dragging a creative over the popup
            this.listVisible = true
            this._updateListVisibility()
        }
    }

    _handlePopupDragLeave(event) {
        if (!this._popupEl) return
        // Only hide if leaving the popup entirely
        if (this._popupEl.contains(event.relatedTarget)) return
        if (this._hasBeenManuallyToggled) return

        // Restore original state if no contexts
        if (this.contexts.length === 0) {
            this.listVisible = false
            this._updateListVisibility()
        }
    }

    // --- Drop zone for adding creatives from tree ---

    _isCreativeDrag(event) {
        return event.dataTransfer.types.includes(CREATIVE_MIME_TYPE)
    }

    _isInternalReorder(event) {
        return event.dataTransfer.types.includes('application/x-context-id')
    }

    handleExternalDragOver(event) {
        if (this._isInternalReorder(event)) return
        if (!this._isCreativeDrag(event)) return
        if (!this.canManage) return

        event.preventDefault()
        event.dataTransfer.dropEffect = 'move'
        this.listTarget.classList.add('context-drop-active')
    }

    handleExternalDragLeave(event) {
        // Only remove highlight if truly leaving the list area
        if (!this.listTarget.contains(event.relatedTarget)) {
            this.listTarget.classList.remove('context-drop-active')
        }
    }

    async handleExternalDrop(event) {
        if (this._isInternalReorder(event)) return
        if (!this._isCreativeDrag(event)) return
        if (!this.canManage) return

        // Always prevent default for creative drags to avoid browser navigation
        event.preventDefault()
        event.stopPropagation()

        this.listTarget.classList.remove('context-drop-active')

        let creativeId = null

        // Try structured MIME type first
        const rawData = event.dataTransfer.getData(CREATIVE_MIME_TYPE)
        if (rawData) {
            try {
                const parsed = JSON.parse(rawData)
                creativeId = parseInt(parsed.creativeId)
            } catch (e) { /* ignore */ }
        }

        // Fallback to text/plain (same drag data serialized to both MIME types)
        if (!creativeId) {
            const textData = event.dataTransfer.getData('text/plain')
            if (textData) {
                try {
                    const parsed = JSON.parse(textData)
                    creativeId = parseInt(parsed.creativeId)
                } catch (e) { /* ignore */ }
            }
        }

        if (!creativeId) return

        await this._addContextId(creativeId)
    }

    _escapeHtml(text) {
        const div = document.createElement('div')
        div.textContent = text
        return div.innerHTML
    }
}
