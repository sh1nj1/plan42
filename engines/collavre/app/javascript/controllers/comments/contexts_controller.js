import { createDragDropRegistry } from '../../lib/dnd/registry'
import { getDragKind, readDragData, writeDragData } from '../../lib/dnd/envelope'
import { previewDrop, horizontalHit } from '../../lib/dnd/preview'
import { alertDialog } from '../../lib/utils/dialog'
import { Controller } from "@hotwired/stimulus"
import PopupToggleGuard from '../../lib/popup_toggle_guard'
import { elementAnchor } from '../../lib/common_popup'

const CONTEXT_LIST_MODAL_ID = 'context-list-modal'
const SELF_CONTEXT_ID = 'self'

export default class extends Controller {
    static targets = ["list", "toggleButton", "bar", "addButton", "listButton"]

    static ICON_CONTEXT_LINK = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>'
    static ICON_CONTEXT_PIN = '<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="17" x2="12" y2="22"/><path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"/></svg>'

    connect() {
        this.contexts = []
        this.canManage = false
        this._activeCreativeId = null
        this._contextLoadVersion = (this._contextLoadVersion || 0) + 1
        this._contextSaveChain = Promise.resolve()
        this._contextMutationLifetime = {}
        this._contextDropNeedsRefresh = false
        this.draggingContextId = null
        this.listVisible = false
        this.handleContextListClose = this.handleContextListClose.bind(this)
        this.element.addEventListener('entity-list:close', this.handleContextListClose)
        this._registerDragDrop()
    }

    disconnect() {
        this._contextMutationLifetime = null
        this.dnd?.destroy()
        this._unbindPopupDragDetection()
        this._contextLoadVersion += 1
        this._closeContextListPopup()
        this.element.removeEventListener('entity-list:close', this.handleContextListClose)
    }

    get creativeId() {
        return this.element.closest('#comments-popup')?.dataset?.creativeId
    }

    onChatWillOpen({ creativeId }) {
        if (String(creativeId) !== String(this._activeCreativeId)) {
            this._resetContextState()
            this._activeCreativeId = creativeId
        }
    }

    async onPopupOpened({ creativeId }) {
	this.onChatWillOpen({ creativeId })
        this._hasBeenManuallyToggled = false
        this.listVisible = false
        this._updateListVisibility()
        await this.loadContexts(creativeId)
        this._bindPopupDragDetection()
    }

    onPopupClosed() {
        this._activeCreativeId = null
        this._resetContextState()
        this._unbindPopupDragDetection()
    }

    _resetContextState() {
        this._contextMutationLifetime = {}
        this._contextDropNeedsRefresh = false
        this._contextLoadVersion += 1
        this._closeContextListPopup()
        this.contexts = []
        this.canManage = false
        this._selfContextDisabled = false
	this.listVisible = false
        if (this.hasListTarget) {
            this.listTarget.innerHTML = ''
        }
	this._updateListVisibility()
	if (this.hasToggleButtonTarget) this.toggleButtonTarget.style.display = 'none'
        if (this.hasAddButtonTarget) this.addButtonTarget.style.display = 'none'
    }

    async loadContexts(creativeId = this.creativeId) {
        if (!creativeId) return
        const loadVersion = ++this._contextLoadVersion

        try {
            const response = await fetch(`/creatives/${creativeId}/contexts`)
            if (response.ok) {
                const data = await response.json()
                if (!this._isCurrentContextLoad(loadVersion, creativeId)) return
                this.contexts = data.contexts || []
                this.canManage = data.can_manage || false
                this._selfContextDisabled = data.disabled_self_context || false
                this.renderContexts()
                this._contextDropNeedsRefresh = false
                return true
            }
        } catch (e) {
            if (!this._isCurrentContextLoad(loadVersion, creativeId)) return
            console.error("Failed to load contexts", e)
        }
        return false
    }

    _isCurrentContextLoad(loadVersion, creativeId) {
        return loadVersion === this._contextLoadVersion && String(creativeId) === String(this.creativeId)
    }

    toggleVisibility() {
        this._hasBeenManuallyToggled = true
        this.listVisible = !this.listVisible
        this._updateListVisibility()
    }

    _updateListVisibility() {
        if (!this.hasListTarget) return
        // The pinned add/list buttons live in the bar alongside the scrolling
        // chips, so visibility is a property of the bar, not of the chip list.
        this._visibilityElement.style.display = this.listVisible ? '' : 'none'

        // Update toggle button active state
        if (this.hasToggleButtonTarget) {
            this.toggleButtonTarget.classList.toggle('context-toggle-active', this.listVisible)
        }
    }

    get _visibilityElement() {
        return this.hasBarTarget ? this.barTarget : this.listTarget
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
                          data-action="click->comments--contexts#toggleContext"
                          data-context-id="${ctx.id}"
                          title="${ctx.inherited ? this.inheritedLabel : ''}">
                        ${this.constructor.ICON_CONTEXT_LINK} ${this._escapeHtml(ctx.description)}`

            html += `<button class="navigate-context-btn" data-action="click->comments--contexts#navigateToContext" data-context-id="${ctx.id}" title="${this.navigateLabel}">\u2192</button>`

            if (this.canManage && !ctx.inherited) {
                html += `<button class="delete-context-btn" data-action="click->comments--contexts#removeContext" data-context-id="${ctx.id}">&times;</button>`
            }

            html += `</span>`
        })

        this.listTarget.innerHTML = html
        this._updateActionButtons()
    }

    _updateActionButtons() {
        if (this.hasAddButtonTarget) {
            this.addButtonTarget.style.display = this.canManage ? '' : 'none'
        }
        this.refreshOpenContextListPopup()
    }

    // --- Context list popup (mirrors the topic list button) ---
    get contextListToggleGuard() {
        this._contextListToggleGuard ||= new PopupToggleGuard()
        return this._contextListToggleGuard
    }

    prepareContextListToggle(event) {
        this.contextListToggleGuard.prepare(event, Boolean(this._contextListPopup()?.popup?.isOpen()))
    }

    finishContextListToggle(event) {
        this.contextListToggleGuard.finish(event)
    }

    cancelContextListToggle(event = {}) {
        this.contextListToggleGuard.cancel(event)
    }

    _contextListPopup() {
        const modal = document.getElementById(CONTEXT_LIST_MODAL_ID)
        return modal && this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
    }

    _closeContextListPopup() {
        const modal = this.element.querySelector(`#${CONTEXT_LIST_MODAL_ID}`)
        const popup = modal && this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
        popup?.close()
        modal?.remove()
        this._contextListToggleGuard?.cancel()
        this.setContextListButtonExpanded(false)
    }

    openContextListPopup(event) {
        if (this.contextListToggleGuard.consume()) return

        const anchor = elementAnchor(event.currentTarget)

        const openWith = (popup) => {
            popup.openForItems(
                this.contextListItems(),
                anchor,
                (item) => this.selectContextListItem(item),
                this.element
            )
            this.setContextListButtonExpanded(true)
        }

        let modal = document.getElementById(CONTEXT_LIST_MODAL_ID)
        if (modal) {
            const popup = this._contextListPopup()
            if (popup?.popup?.isOpen()) {
                popup.close()
                this.setContextListButtonExpanded(false)
            } else if (popup) {
                openWith(popup)
            }
            return
        }

        modal = document.createElement('div')
        modal.id = CONTEXT_LIST_MODAL_ID
        modal.className = 'common-popup'
        modal.style.display = 'none'
        modal.dataset.controller = 'entity-list'
        modal.dataset.closeLabel = this.element.dataset.closeLabel || ''
        modal.innerHTML = `
          <button type="button" class="popup-close-btn" data-entity-list-target="close">&times;</button>
          <input type="text" class="shared-input-surface" style="width:100%;margin-bottom:0.5em;"
            data-entity-list-target="input">
          <ul class="common-popup-list" data-popup-list data-entity-list-target="list"></ul>
        `
        modal.querySelector('input').placeholder = this.element.dataset.contextSearchPlaceholderText || 'Search contexts...'
        // Caged inside the chat box, like the topic list popup.
        this.element.appendChild(modal)

        requestAnimationFrame(() => {
            const popup = this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
            if (popup) openWith(popup)
            else console.error('entity-list controller not found after creation')
        })
    }

    contextListItems() {
        const items = [{
            id: SELF_CONTEXT_ID,
            label: this.currentCreativeSnippet || 'Self',
            iconKey: 'pin',
            muted: this.selfContextDisabled,
            selected: !this.selfContextDisabled,
            actionable: this.canManage,
            statusLabel: this.selfContextDisabled ? this.disabledContextLabel : this.enabledContextLabel
        }]

        this.contexts.forEach(ctx => items.push({
            id: ctx.id,
            label: ctx.description,
            iconKey: 'context',
            muted: Boolean(ctx.disabled),
            selected: !ctx.disabled,
            actionable: this.canManage,
            statusLabel: ctx.disabled ? this.disabledContextLabel : this.enabledContextLabel,
            badge: ctx.inherited ? this.inheritedLabel : null
        }))

        return items
    }

    // Selecting mirrors clicking the chip: it toggles the context on or off.
    // Returning true keeps the popup open so several can be toggled in a row.
    selectContextListItem(item) {
        if (!this.canManage) return true
        if (String(item.id) === SELF_CONTEXT_ID) this.toggleSelfContext()
        else this.toggleContextById(item.id)
        return true
    }

    refreshOpenContextListPopup() {
        const modal = this.element.querySelector(`#${CONTEXT_LIST_MODAL_ID}`)
        const popup = modal && this.application.getControllerForElementAndIdentifier(modal, 'entity-list')
        if (popup?.popup?.isOpen()) popup.updateItems(this.contextListItems())
    }

    handleContextListClose(event) {
        if (event.target?.id !== CONTEXT_LIST_MODAL_ID) return
        this.setContextListButtonExpanded(false)
    }

    setContextListButtonExpanded(expanded) {
        if (this.hasListButtonTarget) {
            this.listButtonTarget.setAttribute('aria-expanded', String(expanded))
        }
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

    get enabledContextLabel() {
        return this.element.dataset.contextEnabledText || 'Enabled'
    }

    get disabledContextLabel() {
        return this.element.dataset.contextDisabledText || 'Disabled'
    }

    get currentCreativeSnippet() {
        const popup = this.element.closest('#comments-popup')
        return popup?.querySelector('#comments-popup-title')?.textContent?.trim()
    }

    get selfContextDisabled() {
        return this._selfContextDisabled || false
    }

    toggleSelfContext(event) {
        if (!this.canManage) return
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

        this.toggleContextById(event.currentTarget.dataset.contextId)
    }

    toggleContextById(contextId) {
        if (!this.canManage) return
        const id = parseInt(contextId)
        if (!id) return

        const ctx = this.contexts.find(c => c.id === id)
        if (!ctx) return

        ctx.disabled = !ctx.disabled
        this.renderContexts()
        this._saveDisabledState()
    }

    removeContext(event) {
        event.stopPropagation()
        const contextId = parseInt(event.currentTarget.dataset.contextId)
        if (!contextId) return Promise.resolve()

        return this._enqueueContextMutation(() => {
            const ownIds = this._ownContextIds()
            if (!ownIds.includes(contextId)) return null
            return ownIds.filter(id => id !== contextId)
        })
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

        const addBtn = this.hasAddButtonTarget ? this.addButtonTarget : this.listTarget.querySelector('.add-context-btn')
        const rect = addBtn?.getBoundingClientRect() || { top: 200, left: 200, bottom: 230, right: 230 }

        linkController.open(rect, (selectedCreative) => {
            this._addContextId(selectedCreative.id)
        })
    }

    _addContextId(creativeId) {
        // Prevent adding self as context
        const id = Number(creativeId)
        if (!Number.isSafeInteger(id) || id <= 0 || id === Number(this.creativeId)) return Promise.resolve()

        return this._enqueueContextMutation(() => {
            // Direct and inherited contexts are both duplicates for a new addition.
            if (this.contexts.some(context => Number(context.id) === id)) return null
            return [...this._ownContextIds(), id]
        })
    }

    _registerDragDrop() {
        this.dnd = createDragDropRegistry({ root: this.element, getKind: getDragKind, readData: readDragData })
        const selector = '.context-chip[draggable="true"]'
        this.dnd.registerDragSource({ selector,
            onDragStart: ({ el, event }) => {
                this.draggingContextId = el.dataset.contextId
                writeDragData(event.dataTransfer, { kind: 'context', ids: [this.draggingContextId], payload: {} })
                event.dataTransfer.effectAllowed = 'move'
                requestAnimationFrame(() => {
                    if (this.draggingContextId === el.dataset.contextId) el.classList.add('context-dragging')
                })
            },
            onDragEnd: ({ el }) => { this.draggingContextId = null; el.classList.remove('context-dragging') } })
        this.dnd.registerDropZone({ selector, accepts: ['context'],
            hitTest: ({ el, event }) => this.canManage && this.draggingContextId && el.dataset.contextId !== this.draggingContextId
                ? horizontalHit({ el, event }) : null,
            preview: previewDrop, onDrop: this.handleReorderDrop.bind(this) })
    }

    handleReorderDrop({ el, ids: draggedIds, hit }) {
        const draggedId = Number(draggedIds[0])
        const targetId = Number(el.dataset.contextId)
        if (!draggedId || !targetId || draggedId === targetId) return Promise.resolve()

        const insertBefore = hit === 'left'

        return this._enqueueContextMutation(() => {
            const ids = this._ownContextIds()
            const draggedIndex = ids.indexOf(draggedId)
            if (draggedIndex === -1 || ids.indexOf(targetId) === -1) return null

            ids.splice(draggedIndex, 1)
            let newIndex = ids.indexOf(targetId)
            if (!insertBefore) newIndex += 1
            ids.splice(newIndex, 0, draggedId)
            return ids
        })
    }

    // --- API calls ---
    async _updateContextIds(ids) {
        return this._patchContexts({ context_ids: ids })
    }

    async _saveDisabledState() {
        const disabledIds = this.contexts.filter(c => c.disabled).map(c => c.id)
        await this._patchContexts({ disabled_context_ids: disabledIds })
    }

    _patchContexts(params) {
        const creativeId = this.creativeId
        if (!creativeId) return Promise.resolve()

        const lifetime = this._contextMutationLifetime
        const save = () => lifetime && lifetime === this._contextMutationLifetime
            ? this._sendContextPatch(creativeId, params) : undefined
        this._contextSaveChain = this._contextSaveChain.then(save, save)
        return this._contextSaveChain
    }

    async _sendContextPatch(creativeId, params) {
        try {
            const response = await fetch(`/creatives/${creativeId}/update_contexts`, {
                method: 'PATCH',
                headers: {
                    'Accept': 'application/json',
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''
                },
                body: JSON.stringify(params)
            })

            if (!response.ok || response.redirected || response.headers?.get('content-type')?.includes('text/html')) {
                console.error('Failed to update contexts', params)
                return false
            }
            return true
        } catch (e) {
            console.error('Error updating contexts', e)
            return false
        }
    }

    // The popup is also a drop zone; the form owns creative-link insertion.
    _bindPopupDragDetection() {
        const popup = this.element.closest('#comments-popup')
        if (!popup) return
        this._unbindPopupDragDetection()
        this.popupDnd = createDragDropRegistry({ root: popup, getKind: getDragKind, readData: readDragData })
        this.popupDnd.registerDropZone({ selector: '#comments-popup', accepts: ['creative'],
            hitTest: ({ event }) => this.canManage && !event.target.closest('#new-comment-form') ? 'into' : null,
            preview: () => {
                this.listVisible = true
                this._updateListVisibility()
                const clear = previewDrop({ el: this.listTarget, hit: 'into' })
                return () => {
                    clear()
                    if (!this._hasBeenManuallyToggled && this.contexts.length === 0) {
                        this.listVisible = false
                        this._updateListVisibility()
                    }
                }
            },
            onDrop: ({ ids, event }) => {
                event.stopPropagation()
                return this._addDroppedContexts(ids)
            } })
    }

    _addDroppedContexts(ids) {
        return this._enqueueContextMutation(() => {
            const selfId = Number(this.creativeId)
            const addedIds = ids.map(Number).filter(id => Number.isSafeInteger(id) && id > 0 && id !== selfId &&
                !this.contexts.some(context => Number(context.id) === id))
            if (!addedIds.length) return null
            return [...new Set([...this._ownContextIds(), ...addedIds])]
        })
    }

    _ownContextIds() {
        return this.contexts.filter(context => !context.inherited).map(context => Number(context.id))
    }

    // `update_contexts` replaces the complete direct-context list, so every whole-list write must
    // build its payload inside this queue. A payload computed while an earlier write was still in
    // flight would silently drop that write's result.
    _enqueueContextMutation(computeIds) {
        const creativeId = this.creativeId
        const lifetime = this._contextMutationLifetime
        const run = async () => {
            if (!this._isContextMutationCurrent(creativeId, lifetime)) return
            if (this._contextDropNeedsRefresh) {
                const refreshed = await this.loadContexts()
                if (!this._isContextMutationCurrent(creativeId, lifetime)) return
                // A superseded load resolves undefined: a newer load owns the rendered list, so the
                // write is dropped without claiming it failed. Only `false` is a real load failure.
                if (refreshed !== true) {
                    if (refreshed === false) alertDialog(this._contextUpdateErrorText)
                    return
                }
            }
            const ids = computeIds()
            if (!ids) return
            const saved = await this._updateContextIds(ids)
            if (!this._isContextMutationCurrent(creativeId, lifetime)) return
            this._contextDropNeedsRefresh = true
            if (saved === false) {
                alertDialog(this._contextUpdateErrorText)
                return
            }
            const refreshed = await this.loadContexts()
            if (this._isContextMutationCurrent(creativeId, lifetime) && refreshed === false) alertDialog(this._contextUpdateErrorText)
        }
        this._contextMutationChain = (this._contextMutationChain || Promise.resolve()).then(run, run)
        return this._contextMutationChain
    }

    _isContextMutationCurrent(creativeId, lifetime) {
        return lifetime !== null && lifetime === this._contextMutationLifetime &&
            String(this.creativeId) === String(creativeId) && this.canManage
    }

    get _contextUpdateErrorText() {
        return this.element.dataset.contextUpdateErrorText
    }

    _unbindPopupDragDetection() {
        this.popupDnd?.destroy()
        this.popupDnd = null
    }

    _escapeHtml(text) {
        const div = document.createElement('div')
        div.textContent = text
        return div.innerHTML
    }
}
