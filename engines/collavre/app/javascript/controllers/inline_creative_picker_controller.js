import visualViewportRect from '../lib/viewport_region'
import LinkCreativeController from './link_creative_controller'

// Reuse the link picker's server-backed tree and search inside a form field.
export default class extends LinkCreativeController {
    connect() {
        this._searchToken = 0
        this._openGeneration = 0
        this._selectOrigin = false
        this._allowCreate = false
        this.reposition = this._reposition.bind(this)
    }

    disconnect() {
        this.close()
    }

    open(_anchor, onSelect, onClose) {
        this.onSelectCallback = onSelect
        this.onCloseCallback = onClose
        this._rootNodes = null
        this._activeEl = null
        this.listTarget.hidden = false
        if (typeof this.listTarget.showPopover === 'function') {
            this.listTarget.showPopover()
        } else {
            this.listTarget.removeAttribute('popover')
        }
        window.addEventListener('resize', this.reposition)
        window.addEventListener('scroll', this.reposition, true)
        window.visualViewport?.addEventListener('resize', this.reposition)
        window.visualViewport?.addEventListener('scroll', this.reposition)
        this.inputTarget.setAttribute('aria-expanded', 'true')
        this._showTree()
    }

    close() {
        this._clearDebounce()
        this._searchToken++
        this._openGeneration++
        this.listTarget.hidePopover?.()
        this.listTarget.hidden = true
        window.removeEventListener('resize', this.reposition)
        window.removeEventListener('scroll', this.reposition, true)
        window.visualViewport?.removeEventListener('resize', this.reposition)
        window.visualViewport?.removeEventListener('scroll', this.reposition)
        this._restoreDialogPosition()
        this.inputTarget.setAttribute('aria-expanded', 'false')
        this.dispatchClose()
    }

    closeOnFocusOut(event) {
        if (!this.element.contains(event.relatedTarget)) this.close()
    }

    handleEscape(event) {
        if (event.key === 'Escape' && !this.listTarget.hidden) {
            event.preventDefault()
            event.stopPropagation()
            this.inputTarget.focus()
            this.close()
        }
    }

    handleInputKeydown(event) {
        this.handleEscape(event)
        if (this.listTarget.hidden) return
        // Enter chooses a result, never submits the enclosing move form.
        if (event.key === 'Enter') event.preventDefault()
        super.handleInputKeydown(event)
    }

    _reposition() {
        if (this.listTarget.hidden) return
        const viewport = visualViewportRect()
        this._makeRoomBelow(viewport)
        const anchor = this.inputTarget.getBoundingClientRect()
        const width = Math.min(anchor.width, viewport.width - 16)
        const top = Math.max(viewport.top + 8, anchor.bottom + 4)
        Object.assign(this.listTarget.style, {
            width: `${width}px`,
            maxHeight: `${Math.max(0, Math.min(320, viewport.bottom - top - 8))}px`,
            left: `${Math.max(viewport.left + 8, Math.min(anchor.left, viewport.right - width - 8))}px`,
            top: `${top}px`,
        })
    }

    _makeRoomBelow(viewport) {
        const dialog = this.element.closest('dialog')
        if (!dialog) return
        const anchor = this.inputTarget.getBoundingClientRect()
        // Keep the input visible and reserve up to three rows below it, even
        // when the keyboard pans or shrinks the visual viewport.
        const minimum = Math.min(120, Math.max(0, viewport.height - anchor.height - 20))
        const bottom = Math.max(viewport.top + 8 + anchor.height,
            Math.min(anchor.bottom, viewport.bottom - minimum - 12))
        if (Math.abs(bottom - anchor.bottom) < 1) return
        if (!this._shiftedDialog) {
            this._shiftedDialog = dialog
            this._originalDialogTop = dialog.style.top
        }
        dialog.style.top = `${dialog.getBoundingClientRect().top + bottom - anchor.bottom}px`
    }

    _restoreDialogPosition() {
        if (!this._shiftedDialog) return
        this._shiftedDialog.style.top = this._originalDialogTop
        this._shiftedDialog = null
    }
}
