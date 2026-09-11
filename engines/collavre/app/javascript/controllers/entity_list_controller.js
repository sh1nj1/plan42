import CommonPopupController from './common_popup_controller'

// Icons are keyed, never injected as raw markup by callers: an entity label can
// come from user input, so the only HTML this popup emits is picked from here.
const ICONS = {
    context: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>',
    pin: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="12" y1="17" x2="12" y2="22"/><path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"/></svg>',
    user: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>'
}

// Searchable vertical popup over a list of already-built items. The topic bar has
// its own controller because topic items carry topic-specific ordering and unread
// rules; contexts and participants share this one.
export default class extends CommonPopupController {
    static targets = ['input', 'list', 'close']

    connect() {
        super.connect()
        this._allItems = []
        this._configureAccessibility()
        this.popup.onActiveChange = () => this._syncActiveDescendant()
        this._onInputBound = this._onInput.bind(this)
        this._onKeydownBound = this.handleInputKeydown.bind(this)
        this._onCloseBound = () => this.close()
        this.inputTarget.addEventListener('input', this._onInputBound)
        this.inputTarget.addEventListener('keydown', this._onKeydownBound)
        this.closeTarget.addEventListener('click', this._onCloseBound)
    }

    _configureAccessibility() {
        if (!this.listTarget.id) this.listTarget.id = `${this.element.id || 'entity-list'}-options`
        this.listTarget.setAttribute('role', 'listbox')
        this.inputTarget.setAttribute('role', 'combobox')
        this.inputTarget.setAttribute('aria-autocomplete', 'list')
        this.inputTarget.setAttribute('aria-haspopup', 'listbox')
        this.inputTarget.setAttribute('aria-controls', this.listTarget.id)
        this.inputTarget.setAttribute('aria-expanded', 'false')
        if (!this.inputTarget.getAttribute('aria-label') && this.inputTarget.placeholder) {
            this.inputTarget.setAttribute('aria-label', this.inputTarget.placeholder)
        }
        const closeLabel = this.element.dataset.closeLabel
        if (closeLabel) this.closeTarget.setAttribute('aria-label', closeLabel)
    }

    disconnect() {
        this.inputTarget?.removeEventListener('input', this._onInputBound)
        this.inputTarget?.removeEventListener('keydown', this._onKeydownBound)
        this.closeTarget?.removeEventListener('click', this._onCloseBound)
        super.disconnect()
    }

    // onSelectCallback may return true to keep the popup open (toggling several
    // entries in a row), anything else closes it.
    openForItems(items, anchorRect, onSelectCallback, boundsElement = null) {
        this.onSelectCallback = onSelectCallback
        this.inputTarget.value = ''
        this.updateItems(items)
        super.open(anchorRect, boundsElement)
        this.inputTarget.setAttribute('aria-expanded', 'true')
        if (this.isMobile()) {
            // Autofocusing the search box raises the virtual keyboard, which covers
            // the very list the user just asked to see. Keep keyboard focus inside
            // the popup without focusing a text field.
            this.closeTarget.focus()
            return
        }
        requestAnimationFrame(() => this.inputTarget.focus())
    }

    updateItems(items = []) {
        const activeItem = this.popup.items[this.popup.activeIndex]
        this._allItems = items
        this._onInput()
        if (!activeItem) return

        const activeIndex = this.popup.items.findIndex(item => String(item.id) === String(activeItem.id))
        if (activeIndex >= 0) this.popup.setActiveIndex(activeIndex)
    }

    setItems(items) {
        super.setItems(items)
        const hasIndependentSelection = items.some((item) =>
            Object.prototype.hasOwnProperty.call(item, 'selected')
        )
        if (hasIndependentSelection) this.listTarget.setAttribute('aria-multiselectable', 'true')
        else this.listTarget.removeAttribute('aria-multiselectable')
        Array.from(this.listTarget.children).forEach((row, index) => {
            row.id = `${this.listTarget.id}-option-${encodeURIComponent(String(items[index]?.id ?? index))}`
            row.setAttribute('role', 'option')
            if (items[index]?.actionable === false) row.setAttribute('aria-disabled', 'true')
            else row.removeAttribute('aria-disabled')
        })
        this._syncActiveDescendant()
    }

    _syncActiveDescendant() {
        const rows = Array.from(this.listTarget.children)
        rows.forEach((row, index) => {
            const item = this.popup.items[index]
            if (Object.prototype.hasOwnProperty.call(item || {}, 'selected')) {
                row.setAttribute('aria-selected', String(Boolean(item.selected)))
            } else {
                row.removeAttribute('aria-selected')
            }
        })
        const activeRow = rows[this.popup.activeIndex]
        if (activeRow) this.inputTarget.setAttribute('aria-activedescendant', activeRow.id)
        else this.inputTarget.removeAttribute('aria-activedescendant')
    }

    isMobile() {
        return window.innerWidth <= 600
    }

    _onInput() {
        const q = this.inputTarget.value.toLowerCase().trim()
        const items = q
            ? this._allItems.filter(i => (i.label || '').toLowerCase().includes(q))
            : this._allItems
        this.setItems(items)
        this.popup?.reposition()
    }

    handleInputKeydown(event) {
        if (event.key === 'Tab') {
            this.close()
            return
        }
	if (event.key === 'Escape') {
	    this.close()
	    return
	}
	this.handleKey(event)
    }

    select(item) {
        if (item?.actionable === false) return
        const keepOpen = this.onSelectCallback ? this.onSelectCallback(item) : false
        if (keepOpen !== true) this.close()
    }

    renderItem(item) {
        const label = this._escape(item.label)
        const icon = ICONS[item.iconKey] || ''
        const avatar = item.avatarUrl
            ? `<img class="entity-list-item-avatar" src="${this._escape(item.avatarUrl)}" alt="">`
            : ''
        const badge = item.badge ? `<span class="entity-list-item-badge">${this._escape(item.badge)}</span>` : ''
        const status = item.statusLabel
            ? `<span class="entity-list-item-status">${this._escape(item.statusLabel)}</span>`
            : ''
        const mutedClass = item.muted ? ' entity-list-item--muted' : ''
        return `<span class="entity-list-item${mutedClass}">${avatar}${icon}<span class="entity-list-item-label">${label}</span>${status}${badge}</span>`
    }

    _escape(value) {
        return String(value == null ? '' : value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
    }

    dispatchClose(reason) {
        this.onSelectCallback = null
        this.inputTarget.setAttribute('aria-expanded', 'false')
        this.inputTarget.removeAttribute('aria-activedescendant')
        super.dispatchClose(reason)
    }
}
