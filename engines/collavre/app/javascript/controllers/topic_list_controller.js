import CommonPopupController from './common_popup_controller'

const ICON_ARCHIVE = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="5" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg>`

export default class extends CommonPopupController {
    static targets = ['input', 'list', 'close']

    connect() {
        super.connect()
        this._allItems = []
        this._onInputBound = this._onInput.bind(this)
        this._onKeydownBound = this.handleInputKeydown.bind(this)
        this._onCloseBound = () => this.close()
        this.inputTarget.addEventListener('input', this._onInputBound)
        this.inputTarget.addEventListener('keydown', this._onKeydownBound)
        this.closeTarget.addEventListener('click', this._onCloseBound)
    }

    disconnect() {
        this.inputTarget?.removeEventListener('input', this._onInputBound)
        this.inputTarget?.removeEventListener('keydown', this._onKeydownBound)
        this.closeTarget?.removeEventListener('click', this._onCloseBound)
        super.disconnect()
    }

    openForTopics({ topics = [], archivedTopics = [], mainTopicId = null, allMessagesLabel = 'All Messages' }, anchorRect, onSelectCallback, boundsElement = null) {
        this.onSelectCallback = onSelectCallback
        this.inputTarget.value = ''
        this.updateTopics({ topics, archivedTopics, mainTopicId, allMessagesLabel })
        super.open(anchorRect, boundsElement)
        if (this.isMobile()) {
            // Autofocusing the search box raises the virtual keyboard, which covers
            // the very list the user just asked to see. Drop focus instead — tapping
            // the box still opens the keyboard when the user actually wants to search.
            this._blurActiveElement()
            return
        }
        requestAnimationFrame(() => this.inputTarget.focus())
    }

    updateTopics({ topics = [], archivedTopics = [], mainTopicId = null, allMessagesLabel = 'All Messages' }) {
        this._allItems = this._buildItems({ topics, archivedTopics, mainTopicId, allMessagesLabel })
        this._onInput()
    }

    isMobile() {
        return window.innerWidth <= 600
    }

    _blurActiveElement() {
        const active = document.activeElement
        if (active && active !== document.body && typeof active.blur === 'function') active.blur()
    }

    _buildItems({ topics, archivedTopics, mainTopicId, allMessagesLabel }) {
        const main = mainTopicId ? topics.find(t => String(t.id) === String(mainTopicId)) : null
        const others = topics.filter(t => !main || String(t.id) !== String(mainTopicId))
        const topicItem = (topic, archived) => {
            const unreadCount = Number(topic.unread_count)
            return {
                id: topic.id,
                label: `#${topic.name}`,
                archived,
                unreadCount: Number.isFinite(unreadCount) ? unreadCount : 0
            }
        }
        const items = []
        if (main) items.push(topicItem(main, false))
        others.forEach(t => items.push(topicItem(t, false)))
        items.push({ id: '', label: `📋 ${allMessagesLabel}`, archived: false })
        archivedTopics.forEach(t => items.push(topicItem(t, true)))
        return items
    }

    _onInput() {
        const q = this.inputTarget.value.toLowerCase().trim()
        if (!q) { this.setItems(this._allItems); return }
        const filtered = this._allItems.filter(i => (i.label || '').toLowerCase().includes(q))
        this.setItems(filtered)
    }

    handleInputKeydown(event) {
        if (this.handleKey(event)) return
        if (event.key === 'Escape') this.close()
    }

    select(item) {
        if (this.onSelectCallback) this.onSelectCallback(item)
        this.close()
    }

    renderItem(item) {
        const escaped = String(item.label || '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
        const unreadBadge = item.unreadCount > 0
            ? `<span class="topic-unread-badge">${item.unreadCount}</span>`
            : ''
        if (item.archived) {
            return `<span class="topic-list-item topic-list-item--archived">${ICON_ARCHIVE}<span class="topic-list-item-label">${escaped}</span>${unreadBadge}</span>`
        }
        return `<span class="topic-list-item"><span class="topic-list-item-label">${escaped}</span>${unreadBadge}</span>`
    }

    dispatchClose(reason) {
        this.onSelectCallback = null
        super.dispatchClose(reason)
    }
}
