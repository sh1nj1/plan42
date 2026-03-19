import CommonPopupController from './common_popup_controller'

export default class extends CommonPopupController {
    static targets = ['input', 'list', 'close']

    connect() {
        super.connect()
        this._debounceTimer = null
        this._allTopics = []
        this._defaultCreateItem = null
        this._creativeId = null
        this._commentIds = null
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

    openForCreative(creativeId, anchorRect, onSelectCallback, mainLabel = 'Main', commentIds = null) {
        this.onSelectCallback = onSelectCallback
        this._allTopics = []
        this._defaultCreateItem = null
        this._creativeId = creativeId
        this._commentIds = commentIds
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
        const q = this.inputTarget.value.toLowerCase().trim()
        if (!q) {
            // No query: show all topics + default create option
            const items = [...this._allTopics]
            if (this._defaultCreateItem) {
                items.push(this._defaultCreateItem)
            }
            this.setItems(items)
            return
        }
        const filtered = this._allTopics.filter(t =>
            (t.label || '').toLowerCase().includes(q)
        )
        // If no match found, show "create and move" option with the query as name
        if (filtered.length === 0) {
            const createLabel = this.element.dataset.createAndMoveText || 'Create "%{name}" and move'
            filtered.push({
                id: '__create__',
                label: `+ ${createLabel.replace('%{name}', this.inputTarget.value.trim())}`,
                createName: this.inputTarget.value.trim(),
                isCreate: true
            })
        }
        this.setItems(filtered)
    }

    async _loadTopics(creativeId, mainLabel) {
        if (!creativeId) return
        try {
            const [topicsResponse, nextNameResponse] = await Promise.all([
                fetch(`/creatives/${creativeId}/topics`, { headers: { Accept: 'application/json' } }),
                fetch(`/creatives/${creativeId}/topics/next_name`, { headers: { Accept: 'application/json' } })
            ])

            const data = await topicsResponse.json()
            const topics = data.topics || []

            this._allTopics = [
                { id: '', label: `📋 ${mainLabel}` },
                ...topics.map(t => ({ id: t.id, label: `#${t.name}` }))
            ]

            // Build default create item from next_name
            if (nextNameResponse.ok) {
                const nextNameData = await nextNameResponse.json()
                const createLabel = this.element.dataset.createAndMoveText || 'Create "%{name}" and move'
                this._defaultCreateItem = {
                    id: '__create_default__',
                    label: `+ ${createLabel.replace('%{name}', nextNameData.name)}`,
                    createName: nextNameData.name,
                    isCreate: true
                }
            }

            const items = [...this._allTopics]
            if (this._defaultCreateItem) {
                items.push(this._defaultCreateItem)
            }
            this.setItems(items)
        } catch (error) {
            console.error('Error loading topics:', error)
            this.setItems([])
        }
    }

    async select(item) {
        if (item.isCreate && this._commentIds && this._commentIds.length > 0) {
            // Create new topic + move comments
            await this._createTopicAndMove(item.createName, this._commentIds)
            this.close()
            return
        }

        if (this.onSelectCallback) {
            this.onSelectCallback(item)
        }
        this.close()
    }

    async _createTopicAndMove(name, commentIds) {
        if (!this._creativeId) return

        try {
            const response = await fetch(`/creatives/${this._creativeId}/topics`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content
                },
                body: JSON.stringify({ topic: { name }, comment_ids: commentIds })
            })

            if (response.ok) {
                const topic = await response.json()
                // Notify via callback so list_controller refreshes
                if (this.onSelectCallback) {
                    this.onSelectCallback({ id: topic.id, label: `#${topic.name}`, created: true })
                }
            } else {
                const data = await response.json().catch(() => ({}))
                console.error('Failed to create topic:', data.errors || data.error)
            }
        } catch (e) {
            console.error('Error creating topic and moving comments', e)
        }
    }

    renderItem(item) {
        const text = item.label || ''
        const escaped = text
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
        if (item.isCreate) {
            return `<span class="topic-create-option">${escaped}</span>`
        }
        return escaped
    }

    dispatchClose(reason) {
        this.onSelectCallback = null
        this._commentIds = null
        this._creativeId = null
        super.dispatchClose(reason)
    }
}
