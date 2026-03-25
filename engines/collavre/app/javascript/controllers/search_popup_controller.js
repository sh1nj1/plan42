import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['input', 'popup', 'overlay']

  connect() {
    this._escHandler = (e) => {
      if (e.key === 'Escape') this.close()
    }
    document.addEventListener('keydown', this._escHandler)

    // Global keyboard shortcut: Cmd/Ctrl + K to open search
    this._shortcutHandler = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault()
        this.toggle()
      }
    }
    document.addEventListener('keydown', this._shortcutHandler)
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

    const query = url.searchParams.toString()
    window.location.href = query ? `${url.pathname}?${query}` : url.pathname
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
    const query = url.searchParams.toString()
    window.location.href = query ? `${url.pathname}?${query}` : url.pathname
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
    const query = url.searchParams.toString()
    window.location.href = query ? `${url.pathname}?${query}` : url.pathname
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
    const query = url.searchParams.toString()
    window.location.href = query ? `${url.pathname}?${query}` : url.pathname
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
    const query = url.searchParams.toString()
    window.location.href = query ? `${url.pathname}?${query}` : url.pathname
  }
}
