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
    this.invalidatedCreativeIds = new Set()
    this.destroyedCreativeIds = new Set()
    this.invalidationGeneration = 0
    this.handleFrameLoad = this.handleFrameLoad.bind(this)
    this.handleTurboRender = this.handleTurboRender.bind(this)
    this.queueRefresh = this.queueRefresh.bind(this)
    document.addEventListener('turbo:frame-load', this.handleFrameLoad)
    document.addEventListener('turbo:frame-render', this.handleFrameLoad)
    document.addEventListener('turbo:render', this.handleTurboRender)
    document.addEventListener('workspace-tree:invalidate', this.queueRefresh)
    document.addEventListener('creative-destroyed', this.queueRefresh)
    window.addEventListener('collavre:creative-drop-complete', this.queueRefresh)
    this.observeWorkspaceFrame()
    this.load({ syncChat: false })
  }

  disconnect() {
    this.loadAbortController?.abort()
    this.frameObserver?.disconnect()
    if (this.refreshTimeout) window.clearTimeout(this.refreshTimeout)
    document.removeEventListener('turbo:frame-load', this.handleFrameLoad)
    document.removeEventListener('turbo:frame-render', this.handleFrameLoad)
    document.removeEventListener('turbo:render', this.handleTurboRender)
    document.removeEventListener('workspace-tree:invalidate', this.queueRefresh)
    document.removeEventListener('creative-destroyed', this.queueRefresh)
    window.removeEventListener('collavre:creative-drop-complete', this.queueRefresh)
  }

  async load({ preserveState = false, showLoading = true, syncChat = true } = {}) {
    this.loadAbortController?.abort()
    this.loadAbortController = new AbortController()
    const invalidationGeneration = this.invalidationGeneration
    this.preservedBranchState = preserveState ? this.branchState() : new Map()
    if (showLoading) this.showStatus(this.loadingTextValue)

    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: 'application/json' },
        signal: this.loadAbortController.signal,
      })
      if (!response.ok) throw new Error(`Failed to load workspace tree: ${response.status}`)

      const data = await response.json()
      const nodes = Array.isArray(data.creatives) ? data.creatives : []
      if (invalidationGeneration === this.invalidationGeneration) this.restoreReadableCreativeIds(nodes)
      this.render(nodes, { syncChat })
    } catch (error) {
      if (error.name === 'AbortError') return
      console.error(error)
      if (showLoading) this.showStatus(this.errorTextValue)
    }
  }

  render(nodes, { syncChat = true } = {}) {
    this.nodesData = nodes
    this.treeTarget.replaceChildren()
    if (nodes.length === 0) {
      this.showStatus(this.emptyTextValue)
      this.syncFromWorkspaceFrame(undefined, { syncChat })
      return
    }

    this.activeId = this.deepestVisiblePathId(nodes, this.currentPathValue)
    this.treeTarget.appendChild(this.buildList(nodes))
    this.syncFromWorkspaceFrame(undefined, { syncChat })
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
    const savedExpanded = this.preservedBranchState?.get(String(node.id))
    const expanded = children.length > 0 && (savedExpanded ?? this.currentPathValue.map(String).includes(String(node.id)))

    if (children.length > 0) {
      const toggle = document.createElement('button')
      toggle.type = 'button'
      toggle.className = 'creative-workspace-tree-branch-toggle'
      toggle.setAttribute('aria-expanded', String(expanded))
      toggle.setAttribute('aria-label', node.label)
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
    link.dataset.turboFrame = 'creative-workspace-content'
    link.dataset.turboAction = 'advance'
    link.dataset.creativeId = String(node.id)
    link.dataset.creativeSnippet = node.snippet || node.label
    link.dataset.canComment = String(node.can_comment === true)
    if (String(node.id) === String(this.activeId)) {
      link.classList.add('is-current')
      link.setAttribute('aria-current', 'page')
    }
    link.addEventListener('click', (event) => this.selectNode(event))
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

  selectNode(event) {
    if (!this.isUnmodifiedPrimaryClick(event)) return

    const link = event.currentTarget
    if (this.invalidatedCreativeIds.has(String(link.dataset.creativeId))) {
      this.closePanel()
      return
    }
    this.setActiveId(link.dataset.creativeId)
    this.closePanel()
    this.openChat(link)
  }

  handleFrameLoad(event) {
    if (event.target.id !== 'creative-workspace-content') return

    this.syncFromWorkspaceFrame(event.target, { authoritative: event.type === 'turbo:frame-load' })
  }

  handleTurboRender() {
    requestAnimationFrame(() => {
      if (this.element.isConnected) this.syncFromWorkspaceFrame()
    })
  }

  observeWorkspaceFrame() {
    const frame = document.getElementById('creative-workspace-content')
    if (!frame) return

    this.frameObserver = new MutationObserver(() => {
      if (this.element.isConnected) this.syncFromWorkspaceFrame(frame)
    })
    this.frameObserver.observe(frame, { childList: true })
  }

  queueRefresh(event) {
    this.rememberInvalidatedCreativeIds(event)
    if (this.refreshTimeout) window.clearTimeout(this.refreshTimeout)
    this.refreshTimeout = window.setTimeout(() => {
      this.refreshTimeout = null
      this.load({ preserveState: true, showLoading: false, syncChat: false })
    }, 100)
  }

  syncFromWorkspaceFrame(
    frame = document.getElementById('creative-workspace-content'),
    { authoritative = false, syncChat = true } = {}
  ) {
    if (!frame) return

    const state = frame.querySelector('[data-workspace-navigation-state]')
    if (!state) return

    const stateCreativeId = state.dataset.creativeId
    const locationCreativeId = this.creativeIdFromLocation()
    if (!stateCreativeId && (authoritative || !locationCreativeId)) {
      this.setActiveId(null)
      if (syncChat) this.openChat(this.rootState())
      return
    }
    if (!stateCreativeId || (!authoritative && stateCreativeId !== locationCreativeId)) return
    if (this.invalidatedCreativeIds.has(String(stateCreativeId))) {
      this.setActiveId(null)
      if (syncChat) this.openChat(this.rootState())
      return
    }

    const path = this.parsePath(state.dataset.creativePath)
    const activeId = this.deepestVisiblePathId(this.nodesData || [], path)
    this.setActiveId(activeId)

    if (syncChat) {
      this.openChat(state, {
        highlightId: authoritative ? this.commentIdFromLocation() : undefined,
      })
    }
  }

  setActiveId(id) {
    this.treeTarget.querySelectorAll('.creative-workspace-tree-link.is-current').forEach((link) => {
      link.classList.remove('is-current')
      link.removeAttribute('aria-current')
    })

    this.activeId = null
    const link = id && this.linkForId(id)
    if (!link) return

    link.classList.add('is-current')
    link.setAttribute('aria-current', 'page')
    this.activeId = String(id)
  }

  openChat(link, { highlightId } = {}) {
    document.dispatchEvent(new CustomEvent('creative-comments-click', {
      detail: {
        button: link,
        creativeId: link.dataset.creativeId,
        workspaceSync: true,
        highlightId,
      },
    }))
  }

  linkForId(id) {
    return [...this.treeTarget.querySelectorAll('.creative-workspace-tree-item[data-creative-id]')]
      .find((item) => item.dataset.creativeId === String(id))
      ?.querySelector(':scope > .creative-workspace-tree-row > .creative-workspace-tree-link')
  }

  branchState() {
    return new Map(
      [...this.treeTarget.querySelectorAll('.creative-workspace-tree-branch-toggle')]
        .map((toggle) => [
          toggle.closest('.creative-workspace-tree-item')?.dataset.creativeId,
          toggle.getAttribute('aria-expanded') === 'true',
        ])
        .filter(([id]) => id)
    )
  }

  creativeIdFromLocation() {
    const queryId = new URLSearchParams(window.location.search).get('id')
    if (queryId) return queryId

    return window.location.pathname.match(/\/creatives\/(\d+)/)?.[1]
  }

  commentIdFromLocation() {
    const params = new URLSearchParams(window.location.search)
    const queryCommentId = params.get('comment_id') || params.get('highlight_comment_id')
    if (queryCommentId) return queryCommentId

    const pathCommentId = window.location.pathname.match(/\/creatives\/\d+\/comments\/(\d+)/)?.[1]
    if (pathCommentId) return pathCommentId

    return window.location.hash.match(/comment_(\d+)/)?.[1]
  }

  rootState() {
    if (!this.rootNavigationState) {
      this.rootNavigationState = document.createElement('div')
      this.rootNavigationState.dataset.workspaceNavigationState = 'true'
    }
    return this.rootNavigationState
  }

  rememberInvalidatedCreativeIds(event) {
    const creativeIds = event?.detail?.creativeIds || []
    if (creativeIds.length > 0) this.invalidationGeneration += 1
    creativeIds.forEach((id) => {
      const creativeId = String(id)
      this.invalidatedCreativeIds.add(creativeId)
      if (event?.type === 'creative-destroyed') this.destroyedCreativeIds.add(creativeId)
    })
  }

  restoreReadableCreativeIds(nodes) {
    const remaining = [...nodes]
    while (remaining.length > 0) {
      const node = remaining.pop()
      const creativeId = String(node.id)
      if (!this.destroyedCreativeIds.has(creativeId)) this.invalidatedCreativeIds.delete(creativeId)
      if (Array.isArray(node.children)) remaining.push(...node.children)
    }
  }

  parsePath(value) {
    try {
      const parsed = JSON.parse(value || '[]')
      return Array.isArray(parsed) ? parsed : []
    } catch (_error) {
      return []
    }
  }

  isUnmodifiedPrimaryClick(event) {
    return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey
  }

  deepestVisiblePathId(nodes, path = []) {
    const visibleIds = new Set()
    const collect = (items) => items.forEach((item) => {
      visibleIds.add(String(item.id))
      collect(Array.isArray(item.children) ? item.children : [])
    })
    collect(nodes)

    return [...path].reverse().find((id) => visibleIds.has(String(id)))
  }

  showStatus(text) {
    const status = document.createElement('p')
    status.className = 'creative-workspace-tree-status'
    status.textContent = text
    this.treeTarget.replaceChildren(status)
  }
}
