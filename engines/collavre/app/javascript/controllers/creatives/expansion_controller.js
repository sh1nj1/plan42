import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../../lib/api/csrf_fetch'
import { renderCreativeTree, dispatchCreativeTreeUpdated } from '../../creatives/tree_renderer'

export default class extends Controller {
  static targets = ['expand']

  connect() {
    this.allExpanded = false
    this.currentCreativeId = null
    this.handleToggleEvent = this.handleToggleEvent.bind(this)
    this.handleTreeUpdated = this.handleTreeUpdated.bind(this)
    this.element.addEventListener('creative-toggle-click', this.handleToggleEvent)
    this.element.addEventListener('creative-tree:updated', this.handleTreeUpdated)
    this.setup()
  }

  disconnect() {
    this.element.removeEventListener('creative-toggle-click', this.handleToggleEvent)
    this.element.removeEventListener('creative-tree:updated', this.handleTreeUpdated)
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

  handleTreeUpdated(event) {
    const container =
      event?.target && typeof event.target.querySelectorAll === 'function'
        ? event.target
        : this.element
    this.initializeRows(container || this.element)
  }

  setup() {
    this.currentCreativeId = this.computeCurrentCreativeId()
    this.allExpanded = false
    this.updateExpandButton()
    this.initializeRows(this.element)
  }

  computeCurrentCreativeId() {
    // Try URL path first: /creatives/:id
    const match = window.location.pathname.match(/\/creatives\/(\d+)/)
    let id = match ? match[1] : null

    // Try URL params: ?id=...
    if (!id) {
      const params = new URLSearchParams(window.location.search)
      id = params.get('id')
    }

    // Fallback: get ID from title row element
    if (!id) {
      const titleRow = this.element.querySelector('creative-tree-row[is-title]')
      id = titleRow?.getAttribute('creative-id')
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
      row.loadingChildren = false
      return Promise.resolve(false)
    }

    if (childrenDiv.dataset.loaded === 'true') {
      const has = !!childrenDiv.querySelector('creative-tree-row')
      row.hasChildren = has
      row.loadingChildren = false
      return Promise.resolve(has)
    }

    const url = childrenDiv.dataset.loadUrl
    if (!url) {
      row.hasChildren = false
      row.loadingChildren = false
      return Promise.resolve(false)
    }

    row.loadingChildren = true

    return fetch(url, { headers: { Accept: 'application/json' } })
      .then((response) => {
        if (!response.ok) throw new Error(`Failed to load children: ${response.status}`)
        return response.json()
      })
      .then((data) => {
        const nodes = Array.isArray(data?.creatives) ? data.creatives : []
        renderCreativeTree(childrenDiv, nodes)
        childrenDiv.dataset.loaded = 'true'
        dispatchCreativeTreeUpdated(childrenDiv)
        const has = !!childrenDiv.querySelector('creative-tree-row')
        row.hasChildren = has
        return has
      })
      .catch((error) => {
        console.error(error)
        row.hasChildren = false
        childrenDiv.dataset.loaded = 'true'
        return false
      })
      .finally(() => {
        row.loadingChildren = false
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
