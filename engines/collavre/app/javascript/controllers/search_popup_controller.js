import { Controller } from '@hotwired/stimulus'
import {
  WORKSPACE_FRAME_ID,
  applyFilterParam,
  buildFilterUrl,
  syncFilterButtons,
  visitFilterUrl
} from '../lib/utils/filter_navigation'

export default class extends Controller {
  static targets = ['input', 'popup', 'overlay']
  static values = { indexPath: String, onIndex: Boolean }

  connect() {
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

    // The GNB survives workspace-frame visits. Tree navigation and frame
    // history traversal bypass _navigate(), so keep its controls aligned with
    // the browser URL whenever that frame loads or history changes.
    this._frameLoadHandler = (event) => {
      if (event.target.id !== WORKSPACE_FRAME_ID) return
      this._syncFromLocation()
    }
    this._historyHandler = () => this._syncFromLocation()
    document.addEventListener('turbo:frame-load', this._frameLoadHandler)
    window.addEventListener('popstate', this._historyHandler)
    this._syncFromLocation()
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
    document.removeEventListener('turbo:frame-load', this._frameLoadHandler)
    window.removeEventListener('popstate', this._historyHandler)
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

    this._navigate((params) => applyFilterParam(params, filter))
  }

  // Apply comment filter
  applyCommentFilter(event) {
    event.preventDefault()
    this._navigate((params) => applyFilterParam(params, 'comment'))
  }

  // Toggle search mode (flat/tree)
  applySearchMode(event) {
    event.preventDefault()
    const mode = event.currentTarget.dataset.mode
    if (!mode) return

    this._navigate((params) => {
      if (mode === 'tree') {
        params.set('search_mode', 'tree')
      } else {
        params.delete('search_mode')
      }
    })
  }

  // Toggle archive visibility via URL parameter
  toggleArchive(event) {
    event.preventDefault()
    this._navigate((params) => {
      if (params.get('show_archived') === 'true') {
        params.delete('show_archived')
      } else {
        params.set('show_archived', 'true')
      }
    })
  }

  _applyFilters(overrides = {}) {
    this._navigate((params) => {
      if (!('search' in overrides)) return

      const search = overrides.search
      if (search.trim()) {
        params.set('search', search)
      } else {
        params.delete('search')
      }
    })
  }

  // The popup lives in the GNB, outside the workspace frame, so a frame-only
  // navigation leaves it open and showing the previous filter state.
  _navigate(mutate) {
    const url = buildFilterUrl(
      { indexPath: this.indexPathValue, onIndex: this.onIndexValue },
      mutate
    )

    this.close()
    if (visitFilterUrl(url)) syncFilterButtons(url)
  }

  _syncFromLocation() {
    const url = new URL(window.location.href)
    syncFilterButtons(url)
    this.inputTarget.value = url.searchParams.get('search') || ''
  }
}
