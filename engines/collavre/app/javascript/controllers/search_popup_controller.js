import { Controller } from '@hotwired/stimulus'

// localStorage key holding the user's most recent creative-index filter set.
// Persisted per browser so search/progress/tag/… conditions survive navigation
// away from and back to the index, matching the "search conditions must
// persist" requirement.
const STORAGE_KEY = 'collavre.creativeSearchFilters'

export default class extends Controller {
  static targets = ['input', 'popup', 'overlay']

  // filterKeys: the canonical list of filter param names (rendered from the
  //   Ruby FilterParams::DISPLAY_KEYS single source of truth).
  // indexPath: the creatives index path; restore only fires there.
  static values = { filterKeys: Array, indexPath: String }

  connect() {
    // Reapply persisted filters when landing on a bare index view. Done first,
    // before wiring handlers, so the (possible) navigation happens immediately.
    this._restoreFilters()

    this._escHandler = (e) => {
      if (e.key === 'Escape') this.close()
    }
    document.addEventListener('keydown', this._escHandler)

    // Global keyboard shortcut: Cmd/Ctrl + K to open search.
    // Skip when focus is inside an editable element (input, textarea,
    // contenteditable, or the inline Lexical editor) so that element's own
    // Ctrl+K behavior (e.g. delete-to-end-of-line) takes precedence over the
    // global search popup.
    this._shortcutHandler = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        if (this._isEditableTarget(e.target)) return
        e.preventDefault()
        this.toggle()
      }
    }
    document.addEventListener('keydown', this._shortcutHandler)
  }

  _isEditableTarget(target) {
    const el = target instanceof Element ? target : document.activeElement
    if (!el || typeof el.closest !== 'function') return false
    const tag = el.tagName
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true
    if (el.isContentEditable) return true
    return Boolean(
      el.closest('[contenteditable]:not([contenteditable="false"]), [data-lexical-editor-root]')
    )
  }

  disconnect() {
    document.removeEventListener('keydown', this._escHandler)
    document.removeEventListener('keydown', this._shortcutHandler)
  }

  open() {
    this.popupTarget.classList.add('open')
    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.add('open')
    }
    // Focus and select all text in input after animation
    requestAnimationFrame(() => {
      this.inputTarget.focus()
      this.inputTarget.select()
    })
  }

  close() {
    this.popupTarget.classList.remove('open')
    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.remove('open')
    }
  }

  toggle() {
    if (this.popupTarget.classList.contains('open')) {
      this.close()
    } else {
      this.open()
    }
  }

  // Handle Enter key in search input
  submitSearch(event) {
    if (event.key === 'Enter') {
      event.preventDefault()
      this._applyFilters({ search: this.inputTarget.value })
    }
  }

  // Apply progress filter (complete/incomplete/all)
  applyProgressFilter(event) {
    event.preventDefault()
    const filter = event.currentTarget.dataset.filter
    if (!filter) return

    const url = new URL(window.location.href)
    url.searchParams.delete('min_progress')
    url.searchParams.delete('max_progress')

    if (filter === 'complete') {
      url.searchParams.set('min_progress', '1')
      url.searchParams.set('max_progress', '1')
    } else if (filter === 'incomplete') {
      url.searchParams.set('min_progress', '0')
      url.searchParams.set('max_progress', '0.99')
    }

    this._navigate(url)
  }

  // Apply comment filter
  applyCommentFilter(event) {
    event.preventDefault()
    const url = new URL(window.location.href)
    if (url.searchParams.get('comment') === 'true') {
      url.searchParams.delete('comment')
    } else {
      url.searchParams.set('comment', 'true')
    }
    this._navigate(url)
  }

  // Toggle search mode (flat/tree)
  applySearchMode(event) {
    event.preventDefault()
    const mode = event.currentTarget.dataset.mode
    if (!mode) return

    const url = new URL(window.location.href)
    if (mode === 'tree') {
      url.searchParams.set('search_mode', 'tree')
    } else {
      url.searchParams.delete('search_mode')
    }
    this._navigate(url)
  }

  // Toggle archive visibility via URL parameter
  toggleArchive(event) {
    event.preventDefault()
    const url = new URL(window.location.href)
    if (url.searchParams.get('show_archived') === 'true') {
      url.searchParams.delete('show_archived')
    } else {
      url.searchParams.set('show_archived', 'true')
    }
    this._navigate(url)
  }

  // Clear all persisted filters and navigate to the unfiltered index.
  reset(event) {
    if (event) event.preventDefault()
    this._clearStored()
    const target = this.hasIndexPathValue ? this.indexPathValue : window.location.pathname
    this._visit(target)
  }

  _applyFilters(overrides = {}) {
    const url = new URL(window.location.href)
    if ('search' in overrides) {
      if (overrides.search) {
        url.searchParams.set('search', overrides.search)
      } else {
        url.searchParams.delete('search')
      }
    }
    this._navigate(url)
  }

  // Persist the resulting filter set, then navigate. Persisting happens on the
  // *write* path (a deliberate filter change) — never on plain page load — so
  // that clearing all filters and navigating to a bare URL leaves the store
  // empty instead of resurrecting stale conditions.
  _navigate(url) {
    this._persist(url)
    const query = url.searchParams.toString()
    this._visit(query ? `${url.pathname}?${query}` : url.pathname)
  }

  // Navigation seams (isolated so behavior can be asserted in tests without a
  // real browser navigation).
  _visit(href) {
    window.location.href = href
  }

  _replaceWith(href) {
    window.location.replace(href)
  }

  _filterKeys() {
    return this.hasFilterKeysValue ? this.filterKeysValue : []
  }

  _persist(url) {
    const stored = {}
    for (const key of this._filterKeys()) {
      const values = url.searchParams.getAll(key)
      if (values.length === 1) {
        stored[key] = values[0]
      } else if (values.length > 1) {
        stored[key] = values
      }
    }
    try {
      if (Object.keys(stored).length > 0) {
        window.localStorage.setItem(STORAGE_KEY, JSON.stringify(stored))
      } else {
        window.localStorage.removeItem(STORAGE_KEY)
      }
    } catch (_) {
      // localStorage unavailable (private mode, disabled) — persistence is a
      // progressive enhancement, so silently continue.
    }
  }

  _clearStored() {
    try {
      window.localStorage.removeItem(STORAGE_KEY)
    } catch (_) {
      // ignore
    }
  }

  _readStored() {
    try {
      const raw = window.localStorage.getItem(STORAGE_KEY)
      if (!raw) return null
      const parsed = JSON.parse(raw)
      return parsed && typeof parsed === 'object' ? parsed : null
    } catch (_) {
      return null
    }
  }

  // Reapply persisted filters, but only on a genuinely bare index view:
  //   - we're on the index path,
  //   - no filter param is present (an explicit filtered URL is authoritative),
  //   - no `id` param (a subtree drill-in must not be hijacked into a global
  //     filtered search).
  // Uses location.replace so the bare URL doesn't pollute history, and never
  // loops: after the replace the URL carries filter params, so the guard below
  // short-circuits on the next connect.
  _restoreFilters() {
    if (!this.hasIndexPathValue) return
    if (window.location.pathname !== this.indexPathValue) return

    const params = new URLSearchParams(window.location.search)
    if (params.has('id')) return
    if (this._filterKeys().some((key) => params.has(key))) return

    const stored = this._readStored()
    if (!stored) return

    const restored = new URLSearchParams()
    for (const key of this._filterKeys()) {
      const value = stored[key]
      if (Array.isArray(value)) {
        value.forEach((entry) => restored.append(key, entry))
      } else if (value != null && value !== '') {
        restored.set(key, value)
      }
    }

    const query = restored.toString()
    if (!query) return

    this._replaceWith(`${this.indexPathValue}?${query}`)
  }
}
