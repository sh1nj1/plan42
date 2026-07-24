import CommonPopupController from './common_popup_controller'
import { escapeHtmlText } from '../utils/html_escape'

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
        this._allItems = this._buildItems({ topics, archivedTopics, mainTopicId, allMessagesLabel })
        this.inputTarget.value = ''
        this.setItems(this._allItems)
        super.open(anchorRect, boundsElement)
        requestAnimationFrame(() => this.inputTarget.focus())
    }

    _buildItems({ topics, archivedTopics, mainTopicId, allMessagesLabel }) {
        const main = mainTopicId ? topics.find(t => String(t.id) === String(mainTopicId)) : null
        const others = topics.filter(t => !main || String(t.id) !== String(mainTopicId))
        const items = []
        if (main) items.push({ id: main.id, label: `#${main.name}`, archived: false })
        others.forEach(t => items.push({ id: t.id, label: `#${t.name}`, archived: false }))
        items.push({ id: '', label: `📋 ${allMessagesLabel}`, archived: false })
        archivedTopics.forEach(t => items.push({ id: t.id, label: `#${t.name}`, archived: true }))
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
        const escaped = escapeHtmlText(item.label || '')
        if (item.archived) {
            return `<span class="topic-list-item topic-list-item--archived">${ICON_ARCHIVE} ${escaped}</span>`
        }
        return `<span class="topic-list-item">${escaped}</span>`
    }

    dispatchClose(reason) {
        this.onSelectCallback = null
        super.dispatchClose(reason)
    }
}
