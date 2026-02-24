import CommonPopupController from './common_popup_controller'

export default class extends CommonPopupController {
    static targets = ['input', 'list', 'close']

    connect() {
        super.connect()
        this._debounceTimer = null
        this._allTopics = []
        this.inputTarget.addEventListener('input', this._onInput.bind(this))
        this.inputTarget.addEventListener('keydown', this.handleInputKeydown.bind(this))
        this.closeTarget.addEventListener('click', () => this.close())
    }

    disconnect() {
        if (this._debounceTimer) {
            clearTimeout(this._debounceTimer)
            this._debounceTimer = null
        }
        super.disconnect()
    }

    openForCreative(creativeId, anchorRect, onSelectCallback, mainLabel = 'Main') {
        this.onSelectCallback = onSelectCallback
        this._allTopics = []
        this.setItems([])
        this.inputTarget.value = ''
        super.open(anchorRect)

        requestAnimationFrame(() => {
            this.inputTarget.focus()
        })

        this._loadTopics(creativeId, mainLabel)
    }

    close() {
        if (this._debounceTimer) {
            clearTimeout(this._debounceTimer)
            this._debounceTimer = null
        }
        super.close()
    }

    handleInputKeydown(event) {
        if (this.handleKey(event)) return
        if (event.key === 'Escape') {
            this.close()
        }
    }

    _onInput() {
        const q = this.inputTarget.value.toLowerCase()
        if (!q) {
            this.setItems(this._allTopics)
            return
        }
        const filtered = this._allTopics.filter(t =>
            (t.label || '').toLowerCase().includes(q)
        )
        this.setItems(filtered)
    }

    async _loadTopics(creativeId, mainLabel) {
        if (!creativeId) return
        try {
            const response = await fetch(`/creatives/${creativeId}/topics`, {
                headers: { Accept: 'application/json' }
            })
            const data = await response.json()
            const topics = data.topics || []

            this._allTopics = [
                { id: '', label: `📋 ${mainLabel}` },
                ...topics.map(t => ({ id: t.id, label: `#${t.name}` }))
            ]
            this.setItems(this._allTopics)
        } catch (error) {
            console.error('Error loading topics:', error)
            this.setItems([])
        }
    }

    select(item) {
        if (this.onSelectCallback) {
            this.onSelectCallback(item)
        }
        this.close()
    }

    renderItem(item) {
        const text = item.label || ''
        return text
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
    }

    dispatchClose(reason) {
        this.onSelectCallback = null
        super.dispatchClose(reason)
    }
}
