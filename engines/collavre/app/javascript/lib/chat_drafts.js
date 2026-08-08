const MAX_DRAFTS = 50
const DRAFT_TTL_MS = 7 * 24 * 60 * 60 * 1000
const CLEAR_EVENT_KEY = 'collavre_chat_drafts_clear'

/**
 * Per-user persistent store for unsent chat input drafts.
 *
 * One localStorage key per user stores drafts keyed by chat id. Blank drafts
 * are removed except for temporary migration tombstones, stale entries expire
 * after seven days, and the oldest drafts are evicted beyond 50 entries.
 */
class ChatDrafts {
  constructor(storage = null) {
    this._storage = storage
  }

  get(chatId) {
    if (!chatId) return null
    const entry = this._load()[String(chatId)]
    return entry?.text || null
  }

  updatedAt(chatId) {
    if (!chatId) return null
    const entry = this._load()[String(chatId)]
    return entry ? entry.updatedAt : null
  }

  set(chatId, text, { preserveBlank = false } = {}) {
    if (!chatId) return

    const id = String(chatId)
    const drafts = this._load()
    if (!text || !text.trim()) {
      if (preserveBlank) {
        // Linked creatives resolve from a raw id to a shared effective id.
        // Keep the clear timestamp long enough for move() to win conflicts.
        const previousUpdatedAt = drafts[id]?.updatedAt || 0
        drafts[id] = { text: '', updatedAt: Math.max(Date.now(), previousUpdatedAt + 1) }
        this._evict(drafts)
      } else {
        if (!(id in drafts)) return
        delete drafts[id]
      }
    } else {
      const previousUpdatedAt = drafts[id]?.updatedAt || 0
      drafts[id] = { text, updatedAt: Math.max(Date.now(), previousUpdatedAt + 1) }
      this._evict(drafts)
    }
    this._save(drafts)
  }

  clear(chatId) {
    this.set(chatId, '')
  }

  move(sourceChatId, targetChatId) {
    if (!sourceChatId || !targetChatId) return

    const sourceId = String(sourceChatId)
    const targetId = String(targetChatId)
    if (sourceId === targetId) return

    const drafts = this._load()
    const source = drafts[sourceId]
    if (!source) return

    const target = drafts[targetId]
    if (!target || source.updatedAt > target.updatedAt) {
      if (source.text) {
        drafts[targetId] = source
      } else {
        delete drafts[targetId]
      }
    }
    delete drafts[sourceId]
    this._save(drafts)
  }

  clearAll({ broadcast = true } = {}) {
    const backend = this._backend()
    const namespace = this._key()
    try {
      backend.removeItem(namespace)
    } catch {
      // Storage unavailable.
    }
    if (!broadcast) return

    try {
      backend.setItem(CLEAR_EVENT_KEY, JSON.stringify({
        namespace,
        nonce: `${Date.now()}-${Math.random()}`,
      }))
    } catch {
      // Storage unavailable.
    }
  }

  wasCleared(event) {
    if (event?.key !== CLEAR_EVENT_KEY || !event.newValue) return false

    try {
      return JSON.parse(event.newValue)?.namespace === this._key()
    } catch {
      return false
    }
  }

  namespace() {
    return this._key()
  }

  _backend() {
    return this._storage || window.localStorage
  }

  _key() {
    const userId = document.body?.dataset?.currentUserId || 'guest'
    return `collavre_chat_drafts_${userId}`
  }

  _evict(drafts) {
    const ids = Object.keys(drafts)
    if (ids.length <= MAX_DRAFTS) return

    ids.sort((a, b) => drafts[a].updatedAt - drafts[b].updatedAt)
    ids.slice(0, ids.length - MAX_DRAFTS).forEach((id) => delete drafts[id])
  }

  _load() {
    try {
      const raw = this._backend().getItem(this._key())
      if (!raw) return {}

      const data = JSON.parse(raw)
      if (!data || typeof data !== 'object' || Array.isArray(data)) return {}

      const cutoff = Date.now() - DRAFT_TTL_MS
      Object.keys(data).forEach((id) => {
        const entry = data[id]
        if (
          !entry ||
          typeof entry.text !== 'string' ||
          typeof entry.updatedAt !== 'number' ||
          entry.updatedAt < cutoff
        ) {
          delete data[id]
        }
      })
      return data
    } catch {
      return {}
    }
  }

  _save(drafts) {
    try {
      this._backend().setItem(this._key(), JSON.stringify(drafts))
    } catch {
      // Storage quota exceeded or storage unavailable.
    }
  }
}

const chatDrafts = new ChatDrafts()

export default chatDrafts
export { ChatDrafts }
