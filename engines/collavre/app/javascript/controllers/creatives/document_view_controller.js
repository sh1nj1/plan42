import { Controller } from '@hotwired/stimulus'

const VIEW_PARAM = 'view'
const VIEW_COOKIE = 'creative_view'
const DOCUMENT_VIEW = 'document'
const COOKIE_MAX_AGE = 60 * 60 * 24 * 365

function storedView() {
  const entry = document.cookie.split('; ').find(cookie => cookie.startsWith(`${VIEW_COOKIE}=`))
  return entry ? entry.slice(VIEW_COOKIE.length + 1) : null
}

function storeView(active) {
  const value = active ? `${DOCUMENT_VIEW}; max-age=${COOKIE_MAX_AGE}` : '; max-age=0'
  document.cookie = `${VIEW_COOKIE}=${value}; path=/; samesite=lax`
}

// Switches the creative list between the default tree and a document-style
// reading view. Both views render the same rows from the same data; the mode
// only changes how a row looks and reacts (see creative_tree_row.js).
//
// The view is a cookie, so it follows the user through the tree whichever way
// they navigate and the server renders it up front. A `?view=` link only picks
// the starting view: it is adopted into the cookie and dropped from the URL.
export default class extends Controller {
  static targets = ['toggle', 'tree']
  static values = { active: Boolean }

  connect() {
    const url = new URL(window.location.href)
    const requested = url.searchParams.get(VIEW_PARAM)
    if (requested === null) {
      // A page restored from the Turbo cache may predate the last toggle.
      this.activeValue = storedView() === DOCUMENT_VIEW
      return
    }
    this.activeValue = requested === DOCUMENT_VIEW
    storeView(this.activeValue)
    url.searchParams.delete(VIEW_PARAM)
    window.history.replaceState(window.history.state, '', url)
  }

  toggle() {
    this.activeValue = !this.activeValue
    storeView(this.activeValue)
  }

  activeValueChanged() {
    const active = this.activeValue
    this.element.classList.toggle('creative-document-view', active)
    if (this.hasToggleTarget) this.toggleTarget.setAttribute('aria-pressed', String(active))
    if (!this.hasTreeTarget) return

    if (active) {
      this.treeTarget.dataset.viewMode = DOCUMENT_VIEW
      this.treeTarget.dataset.dndDisabled = ''
    } else {
      delete this.treeTarget.dataset.viewMode
      delete this.treeTarget.dataset.dndDisabled
    }
    // Rows read the mode from their ancestors while rendering.
    this.element.querySelectorAll('creative-tree-row').forEach(row => row.requestUpdate?.())
  }
}
