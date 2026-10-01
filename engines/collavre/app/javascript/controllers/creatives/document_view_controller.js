import { Controller } from '@hotwired/stimulus'

const VIEW_PARAM = 'view'
const DOCUMENT_VIEW = 'document'

// Switches the creative list between the default tree and a document-style
// reading view. Both views render the same rows from the same data; the mode
// only changes how a row looks and reacts (see creative_tree_row.js).
export default class extends Controller {
  static targets = ['toggle', 'tree']
  static values = { active: Boolean }

  toggle() {
    this.activeValue = !this.activeValue
    this.persist()
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

  // Keep the view in the URL so a reload or a shared link reopens it.
  persist() {
    const url = new URL(window.location.href)
    if (this.activeValue) url.searchParams.set(VIEW_PARAM, DOCUMENT_VIEW)
    else url.searchParams.delete(VIEW_PARAM)
    window.history.replaceState(window.history.state, '', url)
  }
}
