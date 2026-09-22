import LinkCreativeController from './link_creative_controller'

// Reuse the link picker's server-backed tree and search inside a form field.
export default class extends LinkCreativeController {
    connect() {
        this._searchToken = 0
        this._openGeneration = 0
        this._selectOrigin = false
        this._allowCreate = false
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
        this.inputTarget.setAttribute('aria-expanded', 'true')
        this._showTree()
    }

    close() {
        this._clearDebounce()
        this._searchToken++
        this._openGeneration++
        this.listTarget.hidden = true
        this.inputTarget.setAttribute('aria-expanded', 'false')
        this.dispatchClose()
    }

    closeOnFocusOut(event) {
        if (!this.element.contains(event.relatedTarget)) this.close()
    }

    handleInputKeydown(event) {
        if (event.key === 'Escape' && !this.listTarget.hidden) {
            event.preventDefault()
            event.stopPropagation()
            this.close()
            return
        }
        if (this.listTarget.hidden) return
        // Enter chooses a result, never submits the enclosing move form.
        if (event.key === 'Enter') event.preventDefault()
        super.handleInputKeydown(event)
    }

    _reposition() {
        // The result list participates in the dialog's normal layout.
    }
}
