import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['input', 'popup', 'archiveToggle']

  connect() {
    this._outsideClickHandler = (e) => {
      if (!this.element.contains(e.target)) {
        this.close()
      }
    }
    document.addEventListener('click', this._outsideClickHandler)

    this._escHandler = (e) => {
      if (e.key === 'Escape') this.close()
    }
    document.addEventListener('keydown', this._escHandler)

    // Sync archive toggle state from URL
    const url = new URL(window.location.href)
    if (this.hasArchiveToggleTarget) {
      this._archiveActive = url.searchParams.get('show_archived') === 'true'
      this._updateArchiveButton()
    }
  }

  disconnect() {
    document.removeEventListener('click', this._outsideClickHandler)
    document.removeEventListener('keydown', this._escHandler)
  }

  open() {
    this.popupTarget.classList.add('open')
    this.inputTarget.focus()
  }

  close() {
    this.popupTarget.classList.remove('open')
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

  // Toggle archive visibility
  toggleArchive(event) {
    event.preventDefault()
    this._archiveActive = !this._archiveActive
    this._updateArchiveButton()

    // Dispatch event for tree_controller to pick up
    const customEvent = new CustomEvent('search-popup:archive-toggle', {
      bubbles: true,
      detail: { showArchived: this._archiveActive }
    })
    this.element.dispatchEvent(customEvent)

    // Also update the hidden toggle-archived-btn for tree_controller compatibility
    const hiddenBtn = document.getElementById('toggle-archived-btn')
    if (hiddenBtn) {
      hiddenBtn.click()
    }
  }

  _updateArchiveButton() {
    if (!this.hasArchiveToggleTarget) return
    const btn = this.archiveToggleTarget
    btn.classList.toggle('active', this._archiveActive)
    const showText = btn.dataset.showText || ''
    const hideText = btn.dataset.hideText || ''
    btn.textContent = this._archiveActive ? hideText : showText
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
