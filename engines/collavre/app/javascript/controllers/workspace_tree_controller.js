import { Controller } from '@hotwired/stimulus'
import {
  cancelPendingLastVisitedCreative,
  prepareLastVisitedCreativeNavigation,
  rememberLastVisitedCreative,
} from '../lib/last_visited_creative'
// Keep the workspace tree's branch affordance visually aligned with the
// central creative tree (components/creative_tree_row.js#_toggleIcon).
import { CHEVRON_COLLAPSED, CHEVRON_EXPANDED } from '../utils/chevron_icons'

// Module-scoped: a history restore replaces the whole body, swapping this
// controller's instance mid-visit. The instance that observes turbo:visit is
// not necessarily the one that observes the subsequent turbo:render, so the
// visit action must outlive any single instance.
let lastVisitAction = null
const MAX_EXPANDED_BRANCHES = 100
const PANEL_SWIPE_CLOSE_DISTANCE = 50

export default class extends Controller {
  static targets = ['tree', 'panelToggle']

  static values = {
    url: String,
    lastVisitedCreativeUrl: String,
    lastVisitedCreativeVisitToken: String,
    lastVisitedCreativeVisitSequence: Number,
    currentPath: Array,
    loadingText: String,
    emptyText: String,
    errorText: String,
  }

  connect() {
    this.expandedCreativeIds = new Set()
    this.addExpandedPath(this.currentPathValue)
    this.committedExpandedCreativeIds = new Set(this.expandedCreativeIds)
    this.invalidatedCreativeIds = new Set()
    this.destroyedCreativeIds = new Set()
    this.invalidationGeneration = 0
    this.handleFrameLoad = this.handleFrameLoad.bind(this)
    this.handleFrameRequest = this.handleFrameRequest.bind(this)
    this.handleFetchRequest = this.handleFetchRequest.bind(this)
    this.handleTurboRender = this.handleTurboRender.bind(this)
    this.handleVisitStart = this.handleVisitStart.bind(this)
    this.handlePopState = this.handlePopState.bind(this)
    this.handlePanelTouchStart = this.handlePanelTouchStart.bind(this)
    this.handlePanelTouchEnd = this.handlePanelTouchEnd.bind(this)
    this.handleOutsidePanelClick = this.handleOutsidePanelClick.bind(this)
    this.queueRefresh = this.queueRefresh.bind(this)
    window.addEventListener('popstate', this.handlePopState)
    this.element.addEventListener('touchstart', this.handlePanelTouchStart, { passive: true })
    this.element.addEventListener('touchend', this.handlePanelTouchEnd, { passive: true })
    document.addEventListener('turbo:visit', this.handleVisitStart)
    document.addEventListener('turbo:before-fetch-request', this.handleFrameRequest)
    document.addEventListener('turbo:before-fetch-request', this.handleFetchRequest)
    document.addEventListener('turbo:frame-load', this.handleFrameLoad)
    document.addEventListener('turbo:frame-render', this.handleFrameLoad)
    document.addEventListener('turbo:render', this.handleTurboRender)
    document.addEventListener('click', this.handleOutsidePanelClick)
    document.addEventListener('workspace-tree:invalidate', this.queueRefresh)
    document.addEventListener('creative-destroyed', this.queueRefresh)
    window.addEventListener('collavre:creative-drop-complete', this.queueRefresh)
    this.observeWorkspaceFrame()
    // A restore render may reconnect this controller after turbo:render has
    // already fired on the previous, now-disconnected instance's listeners.
    // Re-check the action when the frame callback runs: a newer visit may
    // have started in between and supersedes the restore.
    if (lastVisitAction === 'restore') {
      requestAnimationFrame(() => {
        if (lastVisitAction !== 'restore' || !this.element.isConnected) return

        this.ensureFrameMatchesLocation()
        this.syncFromWorkspaceFrame(undefined, { rememberLastVisited: true })
        lastVisitAction = null
      })
    }
    this.load({ syncChat: false })
  }

  disconnect() {
    this.loadAbortController?.abort()
    this.frameObserver?.disconnect()
    if (this.refreshTimeout) window.clearTimeout(this.refreshTimeout)
    if (this.popStateSyncTimer) window.clearTimeout(this.popStateSyncTimer)
    window.removeEventListener('popstate', this.handlePopState)
    this.element.removeEventListener('touchstart', this.handlePanelTouchStart)
    this.element.removeEventListener('touchend', this.handlePanelTouchEnd)
    document.removeEventListener('turbo:visit', this.handleVisitStart)
    document.removeEventListener('turbo:before-fetch-request', this.handleFrameRequest)
    document.removeEventListener('turbo:before-fetch-request', this.handleFetchRequest)
    document.removeEventListener('turbo:frame-load', this.handleFrameLoad)
    document.removeEventListener('turbo:frame-render', this.handleFrameLoad)
    document.removeEventListener('turbo:render', this.handleTurboRender)
    document.removeEventListener('click', this.handleOutsidePanelClick)
    document.removeEventListener('workspace-tree:invalidate', this.queueRefresh)
    document.removeEventListener('creative-destroyed', this.queueRefresh)
    window.removeEventListener('collavre:creative-drop-complete', this.queueRefresh)
  }

  async load({ showLoading = true, syncChat = true, preserveView = false, focusCreativeId } = {}) {
    this.loadAbortController?.abort()
    this.loadAbortController = new AbortController()
    if (this.pendingRevealPath) this.addExpandedPath(this.pendingRevealPath)
    const requestId = (this.loadRequestId || 0) + 1
    this.loadRequestId = requestId
    const requestedExpandedIds = new Set(this.expandedCreativeIds)
    const requestedRevealPath = this.pendingRevealPath ? [...this.pendingRevealPath] : null
    const invalidationGeneration = this.invalidationGeneration
    const viewState = preserveView ? this.captureViewState(focusCreativeId) : null
    if (showLoading) this.showStatus(this.loadingTextValue)
    this.setTreeBusy(true)

    try {
      const response = await fetch(this.workspaceTreeUrl(requestedExpandedIds), {
        headers: { Accept: 'application/json' },
        signal: this.loadAbortController.signal,
      })
      if (!response.ok) throw new Error(`Failed to load workspace tree: ${response.status}`)

      const data = await response.json()
      if (requestId !== this.loadRequestId) return null

      const nodes = Array.isArray(data.creatives) ? data.creatives : []
      if (invalidationGeneration === this.invalidationGeneration) this.restoreReadableCreativeIds(nodes)
      this.expandedCreativeIds = new Set(requestedExpandedIds)
      this.committedExpandedCreativeIds = new Set(requestedExpandedIds)
      if (requestedRevealPath && this.samePath(requestedRevealPath, this.pendingRevealPath || [])) {
        this.pendingRevealPath = null
      }
      this.render(nodes, { syncChat })
      this.restoreViewState(viewState)
      return true
    } catch (error) {
      if (error.name === 'AbortError' || requestId !== this.loadRequestId) return null

      this.expandedCreativeIds = new Set(this.committedExpandedCreativeIds)
      console.error(error)
      if (showLoading) this.showStatus(this.errorTextValue)
      return false
    } finally {
      if (requestId === this.loadRequestId) this.setTreeBusy(false)
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
    const hasChildren = node.has_children === true || children.length > 0
    const expanded = hasChildren && this.expandedCreativeIds.has(String(node.id))

    if (hasChildren) {
      const toggle = document.createElement('button')
      toggle.type = 'button'
      toggle.className = 'creative-workspace-tree-branch-toggle'
      toggle.setAttribute('aria-expanded', String(expanded))
      toggle.setAttribute('aria-label', node.label)
      toggle.innerHTML = expanded ? CHEVRON_EXPANDED : CHEVRON_COLLAPSED
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
    link.dataset.turboPrefetch = 'false'
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

    if (hasChildren && expanded) {
      const childList = this.buildList(children)
      item.appendChild(childList)
    }

    return item
  }

  async toggleBranch(item, toggle) {
    const creativeId = item.dataset.creativeId
    if (!creativeId) return

    if (this.expandedCreativeIds.has(creativeId)) {
      this.expandedCreativeIds.delete(creativeId)
    } else {
      this.expandedCreativeIds.delete(creativeId)
      this.expandedCreativeIds.add(creativeId)
      this.trimExpandedCreativeIds()
    }

    await this.load({
      showLoading: false,
      syncChat: false,
      preserveView: true,
      focusCreativeId: creativeId,
    })
  }

  togglePanel() {
    const open = this.element.classList.toggle('is-open')
    this.panelToggleTarget.setAttribute('aria-expanded', String(open))
  }

  closePanel() {
    this.element.classList.remove('is-open')
    this.panelToggleTarget.setAttribute('aria-expanded', 'false')
  }

  handleOutsidePanelClick(event) {
    if (!this.element.classList.contains('is-open') || !this.isDrawerViewport()) return
    if (!this.element.contains(event.target)) this.closePanel()
  }

  handlePanelTouchStart(event) {
    if (!this.element.classList.contains('is-open') || event.touches.length !== 1) {
      this.panelTouchStart = null
      return
    }

    const touch = event.touches[0]
    this.panelTouchStart = { x: touch.clientX, y: touch.clientY }
  }

  handlePanelTouchEnd(event) {
    const touchStart = this.panelTouchStart
    this.panelTouchStart = null
    if (!touchStart || event.changedTouches.length !== 1 || !this.isDrawerViewport()) return

    const touch = event.changedTouches[0]
    const horizontalDistance = Math.abs(touch.clientX - touchStart.x)
    const verticalDistance = Math.abs(touch.clientY - touchStart.y)
    if (horizontalDistance >= PANEL_SWIPE_CLOSE_DISTANCE && horizontalDistance > verticalDistance) this.closePanel()
  }

  isDrawerViewport() {
    return window.innerWidth < 1280
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

  handleFrameRequest(event) {
    if (event.target.id !== 'creative-workspace-content') return

    this.frameRequestGeneration = this.invalidationGeneration
  }

  handleFetchRequest(event) {
    prepareLastVisitedCreativeNavigation(
      event,
      this.lastVisitedCreativeVisitTokenValue,
      this.lastVisitedCreativeVisitSequenceValue
    )
  }

  handleVisitStart(event) {
    cancelPendingLastVisitedCreative()
    lastVisitAction = event.detail?.action
  }

  // Turbo only performs a restore visit when the popped entry still carries
  // its own history state; entries whose state was overwritten (or dropped)
  // pop with the URL changing but nothing re-rendering. Watch popstate
  // directly and, once no Turbo visit is processing the traversal, converge
  // the frame onto the URL.
  handlePopState() {
    if (this.popStateSyncTimer) window.clearTimeout(this.popStateSyncTimer)
    this.popStateSyncTimer = window.setTimeout(() => {
      this.popStateSyncTimer = null
      if (window.Turbo?.navigator?.currentVisit) return
      this.ensureFrameMatchesLocation()
    }, 150)
  }

  handleTurboRender() {
    requestAnimationFrame(() => {
      // The restore check must run even from an instance the render just
      // disconnected — it only reads the current document and URL.
      const restoringHistory = lastVisitAction === 'restore'
      if (restoringHistory) this.ensureFrameMatchesLocation()
      if (this.element.isConnected) {
        this.syncFromWorkspaceFrame(undefined, { rememberLastVisited: restoringHistory })
        if (restoringHistory) lastVisitAction = null
      }
    })
  }

  // History restore visits render a cached page snapshot. The snapshot can
  // predate the workspace frame's final content for that history entry, so a
  // back/forward restore may leave the center frame showing a different
  // creative than the URL. Reload the frame from the URL as the source of
  // truth; the resulting authoritative turbo:frame-load resynchronizes the
  // tree and docked chat.
  ensureFrameMatchesLocation() {
    const frame = document.getElementById('creative-workspace-content')
    if (!frame) return

    const state = frame.querySelector('[data-workspace-navigation-state]')
    const stateCreativeId = state?.dataset?.creativeId || null
    const locationCreativeId = this.creativeIdFromLocation() || null
    if (state && stateCreativeId === locationCreativeId) return

    const target = window.location.href
    if (frame.src === target && typeof frame.reload === 'function') {
      frame.reload()
    } else {
      frame.src = target
    }
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
      this.load({ showLoading: false, syncChat: false, preserveView: true })
    }, 100)
  }

  syncFromWorkspaceFrame(
    frame = document.getElementById('creative-workspace-content'),
    { authoritative = false, syncChat = true, rememberLastVisited = false } = {}
  ) {
    if (!frame) return

    const state = frame.querySelector('[data-workspace-navigation-state]')
    if (!state) return

    const stateCreativeId = state.dataset.creativeId
    this.updateLastVisitedCreativeNavigation(state)
    const locationCreativeId = this.creativeIdFromLocation()
    if (!stateCreativeId && (authoritative || !locationCreativeId)) {
      this.currentPathValue = []
      this.pendingRevealPath = null
      this.setActiveId(null)
      if (syncChat) this.openChat(this.rootState())
      return
    }
    if (!stateCreativeId || (!authoritative && stateCreativeId !== locationCreativeId)) return
    if (authoritative) this.restoreCreativeIdFromFrameResponse(stateCreativeId)
    if (this.invalidatedCreativeIds.has(String(stateCreativeId))) {
      this.setActiveId(null)
      if (syncChat) this.openChat(this.rootState())
      return
    }

    const path = this.parsePath(state.dataset.creativePath)
    const pathChanged = !this.samePath(path, this.currentPathValue)
    this.currentPathValue = path
    if (pathChanged) {
      if (this.addExpandedPath(path)) {
        this.pendingRevealPath = [...path]
        this.load({ showLoading: false, syncChat: false, preserveView: true })
      } else {
        this.pendingRevealPath = null
      }
    }
    const activeId = this.deepestVisiblePathId(this.nodesData || [], path)
    this.setActiveId(activeId)

    if (syncChat) {
      this.openChat(state, {
        highlightId: authoritative ? this.commentIdFromLocation() : undefined,
      })
    }

    if (rememberLastVisited) this.rememberLastVisitedCreative(stateCreativeId)
  }

  rememberLastVisitedCreative(creativeId) {
    if (!creativeId || !this.hasLastVisitedCreativeUrlValue || !this.hasLastVisitedCreativeVisitTokenValue) return

    rememberLastVisitedCreative(
      this.lastVisitedCreativeUrlValue,
      creativeId,
      this.lastVisitedCreativeVisitTokenValue,
      this.lastVisitedCreativeVisitSequenceValue
    )
  }

  updateLastVisitedCreativeNavigation(state) {
    const token = state.dataset.lastVisitedCreativeVisitToken
    const sequence = Number(state.dataset.lastVisitedCreativeVisitSequence)
    if (!token || !Number.isFinite(sequence)) return

    this.lastVisitedCreativeVisitTokenValue = token
    this.lastVisitedCreativeVisitSequenceValue = sequence
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

  workspaceTreeUrl(expandedIds = this.expandedCreativeIds) {
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.delete('expand[]')
    expandedIds.forEach((id) => url.searchParams.append('expand[]', id))
    return `${url.pathname}${url.search}${url.hash}`
  }

  addExpandedPath(path) {
    let changed = false
    path.map(String).forEach((id) => {
      if (this.expandedCreativeIds.has(id)) return

      this.expandedCreativeIds.add(id)
      changed = true
    })
    this.trimExpandedCreativeIds(path)
    return changed
  }

  // `protectedPath` is ordered root-first. The server descends only through
  // expanded ancestors, so once the path itself has to be trimmed the set must
  // keep a connected root-to-descendant prefix: evicting the root would collapse
  // the whole tree instead of leaving the first MAX_EXPANDED_BRANCHES levels.
  trimExpandedCreativeIds(protectedPath = this.currentPathValue) {
    const orderedProtectedIds = protectedPath.map(String)
    const protectedIds = new Set(orderedProtectedIds)
    while (this.expandedCreativeIds.size > MAX_EXPANDED_BRANCHES) {
      const evictedId =
        [...this.expandedCreativeIds].find((id) => !protectedIds.has(id)) ??
        this.deepestExpandedId(orderedProtectedIds)
      if (!evictedId) return

      this.expandedCreativeIds.delete(evictedId)
    }
  }

  deepestExpandedId(orderedIds) {
    for (let index = orderedIds.length - 1; index >= 0; index -= 1) {
      if (this.expandedCreativeIds.has(orderedIds[index])) return orderedIds[index]
    }
    return null
  }

  samePath(left, right) {
    return left.length === right.length && left.every((id, index) => String(id) === String(right[index]))
  }

  captureViewState(focusCreativeId) {
    const focusedControl = document.activeElement?.closest?.(
      '.creative-workspace-tree-branch-toggle, .creative-workspace-tree-link'
    )
    const focusedItem = focusedControl?.closest('.creative-workspace-tree-item')
    let focusControl = null
    if (focusCreativeId || focusedControl?.classList.contains('creative-workspace-tree-branch-toggle')) {
      focusControl = 'toggle'
    } else if (focusedControl) {
      focusControl = 'link'
    }

    return {
      scrollTop: this.treeTarget.scrollTop,
      focusCreativeId: focusCreativeId || focusedItem?.dataset.creativeId,
      focusControl,
    }
  }

  restoreViewState(viewState) {
    if (!viewState) return

    this.treeTarget.scrollTop = viewState.scrollTop
    if (!viewState.focusCreativeId || !viewState.focusControl) return

    const item = [...this.treeTarget.querySelectorAll('.creative-workspace-tree-item[data-creative-id]')]
      .find((candidate) => candidate.dataset.creativeId === String(viewState.focusCreativeId))
    const selector = viewState.focusControl === 'toggle'
      ? '.creative-workspace-tree-branch-toggle'
      : '.creative-workspace-tree-link'
    const control = item?.querySelector(`:scope > .creative-workspace-tree-row > ${selector}`)
    control?.focus({ preventScroll: true })
  }

  setTreeBusy(busy) {
    this.treeTarget.setAttribute('aria-busy', String(busy))
    this.treeTarget.querySelectorAll('.creative-workspace-tree-branch-toggle').forEach((toggle) => {
      toggle.disabled = busy
    })
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

  restoreCreativeIdFromFrameResponse(creativeId) {
    const id = String(creativeId)
    if (this.destroyedCreativeIds.has(id)) return
    // Only a frame request started after the latest invalidation proves current access;
    // leaf creatives never appear in the workspace tree payload, so this is their only restore path.
    if (this.frameRequestGeneration !== this.invalidationGeneration) return

    this.invalidatedCreativeIds.delete(id)
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
