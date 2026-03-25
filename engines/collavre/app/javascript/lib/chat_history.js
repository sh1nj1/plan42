const STORAGE_KEY = 'chatNavigationHistory'
const MAX_STACK_SIZE = 20

/**
 * Browser-style back/forward navigation history for chat popups.
 *
 * Each entry: { creativeId, snippet, canComment }
 *
 * Persisted in sessionStorage so it survives page reloads but
 * clears when the browser tab is closed.
 */
class ChatNavigationHistory {
  constructor() {
    this._load()
  }

  /** Record a new chat visit (like navigating to a new URL). */
  push(entry) {
    if (!entry?.creativeId) return

    // If we're already viewing this creative, don't push a duplicate
    if (this.current && this.current.creativeId === entry.creativeId) {
      // Update metadata in case snippet/canComment changed
      this.current.snippet = entry.snippet
      this.current.canComment = entry.canComment
      this._save()
      return
    }

    // Push current to backStack
    if (this.current) {
      this.backStack.push(this.current)
      if (this.backStack.length > MAX_STACK_SIZE) {
        this.backStack.shift()
      }
    }

    // Clear forward stack (new navigation invalidates forward history)
    this.forwardStack = []

    this.current = {
      creativeId: entry.creativeId,
      snippet: entry.snippet || '',
      canComment: !!entry.canComment,
    }

    this._save()
  }

  /** Go back. Returns the entry to navigate to, or null. */
  back() {
    if (!this.canGoBack()) return null

    // Push current to forwardStack
    if (this.current) {
      this.forwardStack.push(this.current)
    }

    this.current = this.backStack.pop()
    this._save()
    return this.current
  }

  /** Go forward. Returns the entry to navigate to, or null. */
  forward() {
    if (!this.canGoForward()) return null

    // Push current to backStack
    if (this.current) {
      this.backStack.push(this.current)
    }

    this.current = this.forwardStack.pop()
    this._save()
    return this.current
  }

  /** Navigate directly to an entry from the recent list. */
  goTo(index) {
    const list = this.recentList()
    if (index < 0 || index >= list.length) return null

    const target = list[index]
    if (target.creativeId === this.current?.creativeId) return null

    // Rebuild stacks: everything before target goes to backStack
    // Forward stack is cleared (like a direct navigation)
    const allEntries = [...this.backStack, this.current, ...this.forwardStack.slice().reverse()]
      .filter(Boolean)

    // Find the target in the combined list and split around it
    const targetIdx = allEntries.findIndex(e => e.creativeId === target.creativeId)
    if (targetIdx === -1) return null

    this.backStack = allEntries.slice(0, targetIdx)
    this.current = allEntries[targetIdx]
    this.forwardStack = allEntries.slice(targetIdx + 1).reverse()

    if (this.backStack.length > MAX_STACK_SIZE) {
      this.backStack = this.backStack.slice(-MAX_STACK_SIZE)
    }

    this._save()
    return this.current
  }

  canGoBack() {
    return this.backStack.length > 0
  }

  canGoForward() {
    return this.forwardStack.length > 0
  }

  /**
   * Returns a unified list of recent chats in chronological order
   * (oldest first), including back stack, current, and forward stack.
   * Each entry has an `isCurrent` flag.
   */
  recentList() {
    const list = []

    for (const entry of this.backStack) {
      list.push({ ...entry, isCurrent: false })
    }

    if (this.current) {
      list.push({ ...this.current, isCurrent: true })
    }

    // Forward stack is newest-first, so reverse for chronological order
    const fwd = [...this.forwardStack].reverse()
    for (const entry of fwd) {
      list.push({ ...entry, isCurrent: false })
    }

    return list
  }

  /** Clear all navigation history. */
  clear() {
    this.backStack = []
    this.forwardStack = []
    this.current = null
    this._save()
  }

  _load() {
    try {
      const raw = window.sessionStorage.getItem(STORAGE_KEY)
      if (raw) {
        const data = JSON.parse(raw)
        this.backStack = Array.isArray(data.backStack) ? data.backStack : []
        this.forwardStack = Array.isArray(data.forwardStack) ? data.forwardStack : []
        this.current = data.current || null
      } else {
        this.backStack = []
        this.forwardStack = []
        this.current = null
      }
    } catch {
      this.backStack = []
      this.forwardStack = []
      this.current = null
    }
  }

  _save() {
    try {
      window.sessionStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          backStack: this.backStack,
          forwardStack: this.forwardStack,
          current: this.current,
        })
      )
    } catch {
      // sessionStorage full or unavailable — silently ignore
    }
  }
}

// Singleton instance
const chatHistory = new ChatNavigationHistory()
export default chatHistory
export { ChatNavigationHistory }
