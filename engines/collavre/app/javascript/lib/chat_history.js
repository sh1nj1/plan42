const STORAGE_KEY = 'chatNavigationHistory'
const MAX_SIZE = 20

/**
 * Circular navigation history for chat popups.
 *
 * Tracks visited chats as an ordered list with a current index.
 * ← (prev) and → (next) cycle through the list endlessly.
 *
 * Example: visited a, b, c (currentIndex = 2, pointing to c)
 *   prev: c → b → a → c → b → a → ...
 *   next: c → a → b → c → a → b → ...
 *
 * Each entry: { creativeId, snippet, canComment }
 *
 * Persisted in sessionStorage (survives reload, clears on tab close).
 */
class ChatNavigationHistory {
  constructor() {
    this._load()
  }

  /** Record a new chat visit. Deduplicates by creativeId. */
  push(entry) {
    if (!entry?.creativeId) return

    const existingIdx = this.entries.findIndex(
      (e) => e.creativeId === entry.creativeId
    )

    if (existingIdx !== -1) {
      // Already in list — update metadata and move cursor there
      this.entries[existingIdx].snippet = entry.snippet || this.entries[existingIdx].snippet
      this.entries[existingIdx].canComment = !!entry.canComment
      this.currentIndex = existingIdx
      this._save()
      return
    }

    // New entry — insert after currentIndex and point to it
    const newEntry = {
      creativeId: entry.creativeId,
      snippet: entry.snippet || '',
      canComment: !!entry.canComment,
    }

    if (this.entries.length === 0) {
      this.entries.push(newEntry)
      this.currentIndex = 0
    } else {
      // Insert right after current position
      const insertAt = this.currentIndex + 1
      this.entries.splice(insertAt, 0, newEntry)
      this.currentIndex = insertAt
    }

    // Evict oldest if over limit
    if (this.entries.length > MAX_SIZE) {
      if (this.currentIndex > 0) {
        this.entries.shift()
        this.currentIndex--
      } else {
        this.entries.pop()
      }
    }

    this._save()
  }

  /** Go to previous chat (cycles). Returns entry or null. */
  prev() {
    if (this.entries.length <= 1) return null
    this.currentIndex =
      (this.currentIndex - 1 + this.entries.length) % this.entries.length
    this._save()
    return this.current()
  }

  /** Go to next chat (cycles). Returns entry or null. */
  next() {
    if (this.entries.length <= 1) return null
    this.currentIndex = (this.currentIndex + 1) % this.entries.length
    this._save()
    return this.current()
  }

  /** Navigate directly to an entry by its index in entries[]. */
  goTo(index) {
    if (index < 0 || index >= this.entries.length) return null
    if (index === this.currentIndex) return null
    this.currentIndex = index
    this._save()
    return this.current()
  }

  /** Returns the current entry, or null. */
  current() {
    if (this.entries.length === 0) return null
    return this.entries[this.currentIndex] || null
  }

  /** Can navigate (needs at least 2 entries). */
  canNavigate() {
    return this.entries.length > 1
  }

  /**
   * Returns all entries with isCurrent flag and original index.
   * Order: visit order (oldest first).
   */
  recentList() {
    return this.entries.map((entry, index) => ({
      ...entry,
      isCurrent: index === this.currentIndex,
      index,
    }))
  }

  /** Remove an entry by creativeId (e.g., when creative is deleted). */
  remove(creativeId) {
    const idx = this.entries.findIndex((e) => e.creativeId === creativeId)
    if (idx === -1) return

    this.entries.splice(idx, 1)

    if (this.entries.length === 0) {
      this.currentIndex = -1
    } else if (idx < this.currentIndex) {
      this.currentIndex--
    } else if (idx === this.currentIndex) {
      // Current was removed — clamp to valid range
      this.currentIndex = Math.min(this.currentIndex, this.entries.length - 1)
    }

    this._save()
  }

  /** Clear all history. */
  clear() {
    this.entries = []
    this.currentIndex = -1
    this._save()
  }

  _load() {
    try {
      const raw = window.sessionStorage.getItem(STORAGE_KEY)
      if (raw) {
        const data = JSON.parse(raw)
        this.entries = Array.isArray(data.entries) ? data.entries : []
        this.currentIndex =
          typeof data.currentIndex === 'number' ? data.currentIndex : -1
        // Clamp
        if (this.entries.length === 0) {
          this.currentIndex = -1
        } else if (
          this.currentIndex < 0 ||
          this.currentIndex >= this.entries.length
        ) {
          this.currentIndex = 0
        }
      } else {
        this.entries = []
        this.currentIndex = -1
      }
    } catch {
      this.entries = []
      this.currentIndex = -1
    }
  }

  _save() {
    try {
      window.sessionStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          entries: this.entries,
          currentIndex: this.currentIndex,
        })
      )
    } catch {
      // sessionStorage full or unavailable
    }
  }
}

// Singleton instance
const chatHistory = new ChatNavigationHistory()
export default chatHistory
export { ChatNavigationHistory }
