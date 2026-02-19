import CommonPopupController from './common_popup_controller'
import creativesApi from '../lib/api/creatives'

export default class extends CommonPopupController {
    static targets = ['input', 'list', 'close']

    connect() {
        super.connect()
        this._debounceTimer = null
        this._searchToken = 0
        this.inputTarget.addEventListener('input', this._debouncedSearch.bind(this))
        this.inputTarget.addEventListener('keydown', this.handleInputKeydown.bind(this))
        this.closeTarget.addEventListener('click', () => this.close())

        // Bind public methods
        this.open = this.open.bind(this)
    }

    disconnect() {
        if (this._debounceTimer) {
            clearTimeout(this._debounceTimer)
            this._debounceTimer = null
        }
        super.disconnect()
    }

    open(anchorRect, onSelectCallback, onCloseCallback) {
        this.onSelectCallback = onSelectCallback
        this.onCloseCallback = onCloseCallback
        this.setItems([])
        this.inputTarget.value = ''
        super.open(anchorRect)

        requestAnimationFrame(() => {
            this.inputTarget.focus()
        })
    }

    close() {
        if (this._debounceTimer) {
            clearTimeout(this._debounceTimer)
            this._debounceTimer = null
        }
        // super.close() calls popup.hide(), which triggers dispatchClose, 
        // where we now handle the callback. So we just need to call super.close().
        super.close()
    }

    handleInputKeydown(event) {
        // Delegate to CommonPopup for navigation
        if (this.handleKey(event)) return

        // Special handling for this specific popup
        if (event.key === 'Escape') {
            this.close()
        }
    }

    _debouncedSearch() {
        if (this._debounceTimer) clearTimeout(this._debounceTimer)
        this._debounceTimer = setTimeout(() => this.search(), 300)
    }

    search() {
        const query = this.inputTarget.value.trim()
        if (query.length < 3) {
            this._searchToken++
            this.setItems([])
            return
        }

        const token = ++this._searchToken
        creativesApi.search(query, { simple: true })
            .then((results) => {
                // Discard stale responses if input changed since this request
                if (token !== this._searchToken) return

                const items = Array.isArray(results)
                    ? results.map((result) => ({ id: result.id, label: result.description }))
                    : []
                this.setItems(items)
            })
            .catch(() => {
                if (token === this._searchToken) this.setItems([])
            })
    }

    // Override select to invoke callback
    select(item) {
        if (this.onSelectCallback) {
            this.onSelectCallback(item)
        }
        this.close()
    }

    renderItem(item) {
        // Escape HTML to prevent XSS since CommonPopup uses innerHTML
        const text = item.label || ''
        return text
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#039;")
    }

    dispatchClose(reason) {
        if (this.onCloseCallback) {
            this.onCloseCallback()
            this.onCloseCallback = null
        }
        // Also clear the callback reference to avoid double calling if close() is called manually later
        this.onSelectCallback = null

        super.dispatchClose(reason)
    }
}
