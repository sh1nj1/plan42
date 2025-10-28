import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../../lib/api/csrf_fetch'

export default class extends Controller {
  static targets = ['expand']

  connect() {
    this.allExpanded = false
    this.currentCreativeId = null
    this.handleToggleEvent = this.handleToggleEvent.bind(this)
    this.element.addEventListener('creative-toggle-click', this.handleToggleEvent)
    this.setup()
  }

  disconnect() {
    this.element.removeEventListener('creative-toggle-click', this.handleToggleEvent)
  }

  toggleAll(event) {
    event.preventDefault()
    this.allExpanded = !this.allExpanded
    const rows = this.element.querySelectorAll('creative-tree-row')
    rows.forEach((row) => {
      if (this.allExpanded) {
        this.expandRow(row, { persist: false })
      } else {
        this.collapseRow(row, { persist: false })
      }
    })
    this.updateExpandButton()
  }

  handleToggleEvent(event) {
    const row = event.detail?.component
    if (!row) return
    this.toggleRow(row)
  }

  setup() {
    this.currentCreativeId = this.computeCurrentCreativeId()
    this.allExpanded = false
    this.updateExpandButton()
    this.initializeRows(this.element)
  }

  computeCurrentCreativeId() {
    const match = window.location.pathname.match(/\/creatives\/(\d+)/)
    let id = match ? match[1] : null
    if (!id) {
      const params = new URLSearchParams(window.location.search)
      id = params.get('id')
    }
    return id
  }

  updateExpandButton() {
    if (!this.hasExpandTarget) return
    const button = this.expandTarget
    const icon = button.querySelector('span')
    if (icon) {
      icon.textContent = this.allExpanded ? '▶' : '▼'
    }
    const expandText = button.dataset.expandText
    const collapseText = button.dataset.collapseText
    button.ariaLabel = this.allExpanded ? collapseText : expandText
  }

  toggleRow(row) {
    if (row.expanded) {
      this.collapseRow(row)
    } else {
      this.expandRow(row)
    }
  }

  expandRow(row, { persist = true } = {}) {
    const creativeId = this.rowCreativeId(row)
    const childrenDiv = this.childrenContainerFor(row)
    this.ensureLoaded(row, childrenDiv).then((hasChildren) => {
      if (!hasChildren || !childrenDiv) {
        this.collapseRow(row, { persist: false })
        return
      }
      childrenDiv.style.display = ''
      childrenDiv.dataset.expanded = 'true'
      row.expanded = true
      if (persist) this.saveExpansionState(creativeId, true)
    })
  }

  collapseRow(row, { persist = true } = {}) {
    const creativeId = this.rowCreativeId(row)
    const childrenDiv = this.childrenContainerFor(row)
    if (childrenDiv) {
      childrenDiv.style.display = 'none'
      childrenDiv.dataset.expanded = 'false'
    }
    row.expanded = false
    if (persist) this.saveExpansionState(creativeId, false)
  }

  ensureLoaded(row, childrenDiv) {
    if (!childrenDiv) {
      row.hasChildren = false
      return Promise.resolve(false)
    }

    if (childrenDiv.dataset.loaded === 'true') {
      const has = !!childrenDiv.querySelector('creative-tree-row')
      row.hasChildren = has
      return Promise.resolve(has)
    }

    const url = childrenDiv.dataset.loadUrl
    if (!url) {
      row.hasChildren = false
      return Promise.resolve(false)
    }

    return fetch(url)
      .then((response) => response.text())
      .then((html) => {
        childrenDiv.innerHTML = html
        childrenDiv.dataset.loaded = 'true'
        this.initializeRows(childrenDiv)
        if (window.attachCreativeRowEditorButtons) window.attachCreativeRowEditorButtons()
        if (window.attachCommentButtons) window.attachCommentButtons()
        const has = !!childrenDiv.querySelector('creative-tree-row')
        row.hasChildren = has
        return has
      })
  }

  initializeRows(container) {
    container.querySelectorAll('creative-tree-row').forEach((row) => {
      this.syncInitialState(row)
    })
  }

  syncInitialState(row) {
    const childrenDiv = this.childrenContainerFor(row)
    const shouldExpand =
      this.allExpanded ||
      row.expanded ||
      (childrenDiv && childrenDiv.dataset.expanded === 'true')

    if (shouldExpand && row.hasChildren) {
      this.expandRow(row, { persist: false })
    } else {
      this.collapseRow(row, { persist: false })
    }
  }

  childrenContainerFor(row) {
    const creativeId = this.rowCreativeId(row)
    if (!creativeId) return null
    return document.getElementById(`creative-children-${creativeId}`)
  }

  rowCreativeId(row) {
    return row.creativeId || row.getAttribute('creative-id')
  }

  saveExpansionState(creativeId, expanded) {
    if (!creativeId) return
    if (this.currentCreativeId === null || this.currentCreativeId === undefined) {
      this.currentCreativeId = this.computeCurrentCreativeId()
    }
    const contextId = this.currentCreativeId ?? null

    csrfFetch('/creative_expanded_states/toggle', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: JSON.stringify({
        creative_id: contextId,
        node_id: creativeId,
        expanded,
      }),
    }).catch(() => {})
  }
}
