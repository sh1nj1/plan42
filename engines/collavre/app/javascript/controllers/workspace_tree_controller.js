import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['tree', 'panelToggle']

  static values = {
    url: String,
    currentPath: Array,
    loadingText: String,
    emptyText: String,
    errorText: String,
  }

  connect() {
    this.abortController = new AbortController()
    this.load()
  }

  disconnect() {
    this.abortController?.abort()
  }

  async load() {
    this.showStatus(this.loadingTextValue)

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: 'application/json' },
        signal: this.abortController.signal,
      })
      if (!response.ok) throw new Error(`Failed to load workspace tree: ${response.status}`)

      const data = await response.json()
      this.render(Array.isArray(data.creatives) ? data.creatives : [])
    } catch (error) {
      if (error.name === 'AbortError') return
      console.error(error)
      this.showStatus(this.errorTextValue)
    }
  }

  render(nodes) {
    this.treeTarget.replaceChildren()
    if (nodes.length === 0) {
      this.showStatus(this.emptyTextValue)
      return
    }

    this.activeId = this.deepestVisiblePathId(nodes)
    this.treeTarget.appendChild(this.buildList(nodes))
  }

  buildList(nodes) {
    const list = document.createElement('ul')
    list.className = 'creative-workspace-tree-list'

    nodes.forEach((node) => list.appendChild(this.buildNode(node)))
    return list
  }

  buildNode(node) {
    const item = document.createElement('li')
    item.className = 'creative-workspace-tree-item'
    item.dataset.creativeId = String(node.id)

    const row = document.createElement('div')
    row.className = 'creative-workspace-tree-row'
    const children = Array.isArray(node.children) ? node.children : []
    const expanded = children.length > 0 && this.currentPathValue.map(String).includes(String(node.id))

    if (children.length > 0) {
      const toggle = document.createElement('button')
      toggle.type = 'button'
      toggle.className = 'creative-workspace-tree-branch-toggle'
      toggle.setAttribute('aria-expanded', String(expanded))
      toggle.textContent = expanded ? '▾' : '▸'
      toggle.addEventListener('click', () => this.toggleBranch(item, toggle))
      row.appendChild(toggle)
    } else {
      const spacer = document.createElement('span')
      spacer.className = 'creative-workspace-tree-branch-spacer'
      spacer.setAttribute('aria-hidden', 'true')
      row.appendChild(spacer)
    }

    const link = document.createElement('a')
    link.href = node.url
    link.textContent = node.label
    link.className = 'creative-workspace-tree-link'
    if (String(node.id) === String(this.activeId)) {
      link.classList.add('is-current')
      link.setAttribute('aria-current', 'page')
    }
    link.addEventListener('click', () => this.closePanel())
    row.appendChild(link)
    item.appendChild(row)

    if (children.length > 0) {
      const childList = this.buildList(children)
      childList.hidden = !expanded
      item.appendChild(childList)
    }

    return item
  }

  toggleBranch(item, toggle) {
    const childList = item.querySelector(':scope > .creative-workspace-tree-list')
    if (!childList) return

    childList.hidden = !childList.hidden
    toggle.setAttribute('aria-expanded', String(!childList.hidden))
    toggle.textContent = childList.hidden ? '▸' : '▾'
  }

  togglePanel() {
    const open = this.element.classList.toggle('is-open')
    this.panelToggleTarget.setAttribute('aria-expanded', String(open))
  }

  closePanel() {
    this.element.classList.remove('is-open')
    this.panelToggleTarget.setAttribute('aria-expanded', 'false')
  }

  deepestVisiblePathId(nodes) {
    const visibleIds = new Set()
    const collect = (items) => items.forEach((item) => {
      visibleIds.add(String(item.id))
      collect(Array.isArray(item.children) ? item.children : [])
    })
    collect(nodes)

    return [...this.currentPathValue].reverse().find((id) => visibleIds.has(String(id)))
  }

  showStatus(text) {
    const status = document.createElement('p')
    status.className = 'creative-workspace-tree-status'
    status.textContent = text
    this.treeTarget.replaceChildren(status)
  }
}
