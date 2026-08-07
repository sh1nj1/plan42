import { Controller } from '@hotwired/stimulus'
import { renderCreativeTree, appendCreativeNodes, dispatchCreativeTreeUpdated } from '../../creatives/tree_renderer'
import { parseEmojis } from '../../utils/emoji_parser'
import {
  hideTreeEmptyState,
  restoreTreeEmptyState,
  PAGINATION_PENDING_ATTRIBUTE,
} from '../../modules/creative_tree_empty_state'

const TREE_RETRY_DELAYS_MS = [200, 600]

export default class extends Controller {
  static values = {
    url: String,
    // Neither fallback is an HTML string any more: showEmptyState() clones the
    // server-rendered <template>, and the load-error fallback is a bare
    // translated sentence the client wraps in a <p> itself. Reading markup back
    // out of a data attribute and assigning it is an innerHTML sink as far as
    // CodeQL (js/xss-through-dom) is concerned, and neither needs to be one.
    errorText: String,
    // Accessible name for the loading placeholder. Server-supplied so it is
    // translated like everything else; the literal below is only a fallback for
    // contexts that render the controller without the value (tests, extensions).
    loadingText: String,
  }

  connect() {
    this.abortController = null
    this.loadingIndicator = null
    this._editing = false
    this._reloadHoldCount = 0
    this._pagination = null
    this._sentinel = null
    this._sentinelObserver = null
    this._loadingMore = false
    this._loadMoreAbort = null
    this._loadMoreIndicator = null
    this.handleResize = this.updateAlignmentOffset.bind(this)
    this.handleTreeUpdated = () => this.queueAlignmentUpdate()
    this._handleEditStart = () => { this._editing = true }
    this._handleEditStop = () => {
      this._editing = false
      // Apply any pending sync data that was deferred while editing
      this._applyPendingSyncData()
      this._drainPendingReload()
    }
    document.documentElement.classList.remove('creative-alignment-ready')
    if (!this.hasCachedContent()) {
      this.load()
    }
    this.queueAlignmentUpdate()
    window.addEventListener('resize', this.handleResize)
    this.element.addEventListener('creative-tree:updated', this.handleTreeUpdated)
    document.addEventListener('creative-editing:start', this._handleEditStart)
    document.addEventListener('creative-editing:stop', this._handleEditStop)
    this._handleSyncRefetch = () => this.requestReload()
    document.addEventListener('creative-sync:refetch', this._handleSyncRefetch)
    this._setupArchiveToggle()
  }

  disconnect() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
    if (this._retryTimer) {
      clearTimeout(this._retryTimer)
      this._retryTimer = null
    }
    window.removeEventListener('resize', this.handleResize)
    this.element.removeEventListener('creative-tree:updated', this.handleTreeUpdated)
    document.removeEventListener('creative-editing:start', this._handleEditStart)
    document.removeEventListener('creative-editing:stop', this._handleEditStop)
    document.removeEventListener('creative-sync:refetch', this._handleSyncRefetch)
    this._teardownPagination()
    if (this._debouncedLoadTimer) clearTimeout(this._debouncedLoadTimer)
    if (this._archiveToggleHandler) {
      document.getElementById('toggle-archived-btn')?.removeEventListener('click', this._archiveToggleHandler)
      document.getElementById('toggle-archived-btn-mobile')?.removeEventListener('click', this._archiveToggleHandler)
    }
  }

  _setupArchiveToggle() {
    const btn = document.getElementById('toggle-archived-btn')
    const mobileBtn = document.getElementById('toggle-archived-btn-mobile')
    if (!btn && !mobileBtn) return

    this._showingArchived = false

    const toggle = () => {
      this._showingArchived = !this._showingArchived

      // Update button (now a labeled overflow-menu item)
      if (btn) {
        btn.classList.toggle('active', this._showingArchived)
        const label = this._showingArchived ? (btn.dataset.hideText || '') : (btn.dataset.showText || '')
        btn.title = label
        // Update visible text while preserving the icon span
        const iconSpan = btn.querySelector('span')
        const iconHtml = iconSpan ? iconSpan.outerHTML + ' ' : ''
        btn.innerHTML = iconHtml + label
      }

      // Update mobile button text (legacy, kept for backward compat)
      if (mobileBtn) {
        const label = this._showingArchived ? (mobileBtn.dataset.hideText || '') : (mobileBtn.dataset.showText || '')
        const iconSpan = mobileBtn.querySelector('span')
        const iconHtml = iconSpan ? iconSpan.outerHTML + ' ' : ''
        mobileBtn.innerHTML = iconHtml + label
      }

      const url = new URL(this.urlValue, window.location.origin)
      if (this._showingArchived) {
        url.searchParams.set('show_archived', 'true')
      } else {
        url.searchParams.delete('show_archived')
      }
      this.urlValue = url.pathname + url.search
      this.element.innerHTML = ''
      delete this.element.dataset.loaded
      this.load()
    }

    this._archiveToggleHandler = toggle
    if (btn) btn.addEventListener('click', toggle)
    if (mobileBtn) mobileBtn.addEventListener('click', toggle)
  }

  _applyPendingSyncData() {
    // After editor closes, apply any sync data that was deferred
    const pendingRows = this.element.querySelectorAll('creative-tree-row[data-pending-sync-data]')
    if (pendingRows.length === 0) return

    // Dynamic import to avoid circular dependency
    import('../../creatives/tree_renderer').then(({ applyRowProperties }) => {
      pendingRows.forEach(row => {
        try {
          const data = JSON.parse(row.dataset.pendingSyncData)
          applyRowProperties(row, data)
        } catch (e) {
          console.warn('[TreeController] Failed to apply pending sync data', e)
        }
        delete row.dataset.pendingSyncData
      })
    })
  }

  debouncedLoad() {
    if (this._debouncedLoadTimer) clearTimeout(this._debouncedLoadTimer)
    this._debouncedLoadTimer = setTimeout(() => {
      // Re-check rather than trusting the check requestReload() already made.
      // Switching rows is a `creative-editing:stop` immediately followed by a
      // `creative-editing:start`, so a refetch drained on the stop is still
      // sitting in this debounce window when the next row opens — and load()
      // replaces the whole container, which would take that row, the editor
      // attached inside it and the unsaved draft out of the document. Re-pend
      // instead of dropping it: the reload is still owed, just not yet safe.
      if (this._editing || this._reloadHoldCount > 0) {
        this._pendingRefetch = true
        return
      }
      this.load()
    }, 300)
  }

  // Editing-aware reload — the entry point for anything that wants the tree
  // refetched in response to something that already happened elsewhere (the sync
  // channel, an archive/unarchive that landed, a delete that promoted children to
  // the root). load() replaces the whole container, which takes the row an open
  // editor is attached to out of the document along with the unsaved draft inside
  // it; those callers can land at any moment, including long after the user has
  // moved on to editing a different row. So the reload waits for
  // `creative-editing:stop`, which _handleEditStop drains.
  //
  // Call load() directly only for reloads the user just asked for and is waiting
  // on (filter change, archive toggle), where re-rendering is the point.
  requestReload() {
    if (this._editing || this._reloadHoldCount > 0) {
      this._pendingRefetch = true
      return
    }
    this.debouncedLoad()
  }

  // Keep editing-aware reloads pending while an operation is between its local
  // edit flush and its server response. The counter makes overlapping requests
  // release independently without allowing an early reload between them.
  beginReloadHold() {
    this._reloadHoldCount += 1
  }

  endReloadHold() {
    if (this._reloadHoldCount > 0) this._reloadHoldCount -= 1
    this._drainPendingReload()
  }

  _drainPendingReload() {
    if (!this._pendingRefetch || this._editing || this._reloadHoldCount > 0) return
    this._pendingRefetch = false
    this.debouncedLoad()
  }

  load() {
    if (!this.hasUrlValue) return

    // A fresh load replaces the whole list (filter change, archive toggle, sync
    // refetch), so any active load-more session is stale — tear it down before
    // re-rendering page 1.
    this._teardownPagination()

    if (this.abortController) {
      this.abortController.abort()
    }
    this.abortController = new AbortController()
    this._retryCount = 0
    this.showLoadingIndicator()
    this._fetchTree()
  }

  _fetchTree() {
    fetch(this.urlValue, {
      headers: { Accept: 'application/json' },
      signal: this.abortController.signal,
    })
      .then((response) => {
        if (!response.ok) throw new Error(`Failed to load creatives: ${response.status}`)
        return response.json()
      })
      .then((data) => {
        this.hideLoadingIndicator()
        this.renderData(data)
      })
      .catch((error) => {
        if (error.name === 'AbortError') return
        // Transient network failures (ERR_NETWORK_CHANGED, offline blips, VPN
        // toggles) surface as TypeError "Failed to fetch". Retry briefly so a
        // momentary network event doesn't leave the user with an empty tree.
        if (this._isTransientNetworkError(error) && this._retryCount < TREE_RETRY_DELAYS_MS.length) {
          const delay = TREE_RETRY_DELAYS_MS[this._retryCount]
          this._retryCount += 1
          this._retryTimer = setTimeout(() => this._fetchTree(), delay)
          return
        }
        console.error(error)
        this.hideLoadingIndicator()
        this.showErrorState()
      })
  }

  _isTransientNetworkError(error) {
    return error instanceof TypeError && /fetch|network/i.test(error.message || '')
  }

  renderData(data) {
    const nodes = Array.isArray(data?.creatives) ? data.creatives : []

    if (nodes.length === 0) {
      this.showEmptyState()
      dispatchCreativeTreeUpdated(this.element)
      return
    }

    renderCreativeTree(this.element, nodes)
    this.markContentLoaded()
    dispatchCreativeTreeUpdated(this.element)
    this.queueAlignmentUpdate()
    this._setupPagination(data?.pagination)
  }

  // --- Load-more (paginated "Chats" feed) -------------------------------------
  // Only engaged when the JSON response carries a `pagination` object (the
  // comment filter). For the tree and search views the payload has no
  // pagination, so none of this runs and behavior is unchanged.

  _setupPagination(pagination) {
    this._teardownPagination()
    this._pagination = pagination || null
    if (!this._pagination || !this._pagination.has_more) return
    if (typeof IntersectionObserver === 'undefined') return
    // Deleting every rendered row does not empty the feed while further pages are
    // queued, so suppress the empty-state placeholder until the last page lands.
    this.element.setAttribute(PAGINATION_PENDING_ATTRIBUTE, 'true')
    this._createSentinel()
  }

  _createSentinel() {
    const sentinel = document.createElement('div')
    sentinel.className = 'creative-chats-load-sentinel'
    sentinel.setAttribute('aria-hidden', 'true')
    this.element.appendChild(sentinel)
    this._sentinel = sentinel
    this._sentinelObserver = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) this._loadMore()
    }, { root: null, rootMargin: '300px' })
    this._sentinelObserver.observe(sentinel)
  }

  _loadMore() {
    if (this._loadingMore) return
    const nextPage = this._pagination && this._pagination.next_page
    if (!nextPage) return

    this._loadingMore = true
    this._showLoadMoreIndicator()

    // Tie this request to an AbortController so a fresh load() / teardown (filter
    // change, archive toggle, sync refetch, disconnect) cancels an in-flight
    // page fetch. Without this the stale promise could append rows for a
    // different urlValue into the freshly rendered list and resurrect the
    // pagination state via _repositionSentinel().
    if (this._loadMoreAbort) this._loadMoreAbort.abort()
    this._loadMoreAbort = new AbortController()
    const signal = this._loadMoreAbort.signal

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set('page', String(nextPage))

    fetch(url.pathname + url.search, { headers: { Accept: 'application/json' }, signal })
      .then((response) => {
        if (!response.ok) throw new Error(`Failed to load more chats: ${response.status}`)
        return response.json()
      })
      .then((data) => {
        if (signal.aborted) return
        this._hideLoadMoreIndicator()
        const nodes = Array.isArray(data?.creatives) ? data.creatives : []
        if (nodes.length > 0) {
          // Belt and braces alongside the pagination-pending guard: a placeholder
          // that slipped through must never sit above the rows being appended.
          hideTreeEmptyState(this.element)
          appendCreativeNodes(this.element, nodes)
          dispatchCreativeTreeUpdated(this.element)
          this.queueAlignmentUpdate()
        }
        this._loadingMore = false
        this._pagination = data?.pagination || null
        if (this._pagination && this._pagination.has_more) {
          this._repositionSentinel()
        } else {
          this._teardownPagination()
          // Last page in, and the rows that were on screen when it was requested
          // may since have been deleted. Nothing is pending any more, so an empty
          // container now genuinely is an empty feed.
          restoreTreeEmptyState(this.element)
        }
      })
      .catch((error) => {
        if (error.name === 'AbortError') return
        console.error(error)
        this._hideLoadMoreIndicator()
        this._loadingMore = false
        // Leave the sentinel in place so a later scroll can retry the page.
      })
  }

  _repositionSentinel() {
    // New rows were appended after the sentinel; move it back to the tail so it
    // keeps trailing the list and can trigger the following page.
    if (this._sentinel && this._sentinel.parentNode === this.element) {
      this.element.appendChild(this._sentinel)
    } else {
      this._createSentinel()
    }
  }

  _teardownPagination() {
    this.element.removeAttribute(PAGINATION_PENDING_ATTRIBUTE)
    if (this._loadMoreAbort) {
      this._loadMoreAbort.abort()
      this._loadMoreAbort = null
    }
    if (this._sentinelObserver) {
      this._sentinelObserver.disconnect()
      this._sentinelObserver = null
    }
    if (this._sentinel && this._sentinel.parentNode) {
      this._sentinel.remove()
    }
    this._sentinel = null
    this._pagination = null
    this._loadingMore = false
    this._hideLoadMoreIndicator()
  }

  _showLoadMoreIndicator() {
    if (this._loadMoreIndicator) return
    const indicator = document.createElement('div')
    indicator.className = 'creative-tree-loading-placeholder creative-chats-load-more'
    indicator.setAttribute('role', 'status')
    indicator.setAttribute('aria-live', 'polite')
    indicator.innerHTML = `
      <span class="creative-loading-indicator" aria-hidden="true">
        <span class="creative-loading-dot">.</span>
        <span class="creative-loading-dot">.</span>
        <span class="creative-loading-dot">.</span>
      </span>
    `
    this.element.appendChild(indicator)
    this._loadMoreIndicator = indicator
  }

  _hideLoadMoreIndicator() {
    if (this._loadMoreIndicator && this._loadMoreIndicator.parentNode) {
      this._loadMoreIndicator.remove()
    }
    this._loadMoreIndicator = null
  }

  showEmptyState() {
    // The placeholder comes from the server-rendered <template> rather than an
    // HTML string on a data attribute: no innerHTML sink, and the button_to CSRF
    // token in the "request permission" variant survives.
    this.element.replaceChildren()
    restoreTreeEmptyState(this.element)
    this.markContentLoaded()
    document.documentElement.classList.add('creative-alignment-ready')
  }

  // Distinct from showEmptyState(): used when the tree fetch itself fails
  // (non-2xx, JSON parse failure, or a non-transient network error after
  // retries are exhausted). The request never actually confirmed the tree is
  // empty, so this must NOT render the Add/Import creation CTAs — a workspace
  // that genuinely has creatives would otherwise look empty and invite
  // duplicate creation.
  showErrorState() {
    this.element.replaceChildren()
    if (this.hasErrorTextValue && this.errorTextValue) {
      const message = document.createElement('p')
      message.className = 'creative-tree-error'
      message.style.textAlign = 'center'
      message.textContent = this.errorTextValue
      this.element.appendChild(message)
    }
    this.markContentLoaded()
    document.documentElement.classList.add('creative-alignment-ready')
  }

  showLoadingIndicator() {
    if (!this.loadingIndicator) {
      // The first load's placeholder is already in the DOM: index.html.erb renders
      // it inside #creatives so the initial paint says "loading" rather than
      // flashing the empty state until Stimulus boots. Adopt that node instead of
      // building a replacement — swapping it out would blank the container for a
      // frame, which is the flicker this whole arrangement exists to avoid.
      this.loadingIndicator =
        this.element.querySelector(':scope > [data-creatives-tree-loading]') || this.buildLoadingIndicator()
    }
    this.clearLoadedState()
    // replaceChildren over `innerHTML = ''` + appendChild: the adopted placeholder
    // is a child of the container, so wiping first would detach the very node
    // being re-inserted.
    this.element.replaceChildren(this.loadingIndicator)
    this.startAnimation()
  }

  buildLoadingIndicator() {
    const indicator = document.createElement('div')
    indicator.className = 'creative-tree-loading-placeholder'
    indicator.setAttribute('data-creatives-tree-loading', '')
    indicator.setAttribute('role', 'status')
    indicator.setAttribute('aria-live', 'polite')
    indicator.setAttribute('aria-label', this.loadingLabel())
    indicator.innerHTML = `
      <span class="creative-loading-indicator" aria-hidden="true">
        <span class="creative-loading-dot">.</span>
        <span class="creative-loading-dot">.</span>
        <span class="creative-loading-dot">.</span>
      </span>
    `
    return indicator
  }

  loadingLabel() {
    if (this.hasLoadingTextValue && this.loadingTextValue) return this.loadingTextValue
    return 'Loading creatives'
  }

  hideLoadingIndicator() {
    this.stopAnimation()
    if (this.loadingIndicator && this.loadingIndicator.parentNode === this.element) {
      this.element.removeChild(this.loadingIndicator)
    }
  }

  startAnimation() {
    if (this.animationInterval) return

    const style = getComputedStyle(document.body)
    let emojiString = style.getPropertyValue('--creative-loading-emojis').replace(/"/g, '').trim()

    if (!emojiString) {
      const rootStyle = getComputedStyle(document.documentElement)
      emojiString = rootStyle.getPropertyValue('--creative-loading-emojis').replace(/"/g, '').trim()
    }

    const emojis = parseEmojis(emojiString)

    let emojiIndex = 0
    let frame = 0 // 0: ..., 1: ..E, 2: .E., 3: E..

    const updateDots = () => {
      if (!this.loadingIndicator) return
      const dots = this.loadingIndicator.querySelectorAll('.creative-loading-dot')
      if (dots.length !== 3) return

      const currentEmoji = emojis[emojiIndex]

      switch (frame) {
        case 0:
          dots[0].textContent = '.'
          dots[1].textContent = '.'
          dots[2].textContent = '.'
          break
        case 1:
          dots[0].textContent = '.'
          dots[1].textContent = '.'
          dots[2].textContent = currentEmoji
          break
        case 2:
          dots[0].textContent = '.'
          dots[1].textContent = currentEmoji
          dots[2].textContent = '.'
          break
        case 3:
          dots[0].textContent = currentEmoji
          dots[1].textContent = '.'
          dots[2].textContent = '.'
          break
      }

      frame++
      if (frame > 3) {
        frame = 0
        emojiIndex = (emojiIndex + 1) % emojis.length
      }
    }

    this.animationInterval = setInterval(updateDots, 120)
    updateDots() // Initial call
  }

  stopAnimation() {
    if (this.animationInterval) {
      clearInterval(this.animationInterval)
      this.animationInterval = null
    }
  }

  hasCachedContent() {
    if (this.element.dataset.loaded !== 'true') return false
    return Boolean(this.element.querySelector('creative-tree-row') || this.element.innerHTML.trim() !== '')
  }

  markContentLoaded() {
    this.element.dataset.loaded = 'true'
  }

  clearLoadedState() {
    delete this.element.dataset.loaded
  }

  updateAlignmentOffset() {
    const actionsRow = document.querySelector('.creative-actions-row')
    const title = document.querySelector('.page-title')
    if (!actionsRow && !title) return false

    const content = this.element.querySelector('.creative-tree .creative-content')
    if (!content) return false

    const parent = (actionsRow || title)?.parentElement
    if (!parent) return false

    const contentRect = content.getBoundingClientRect()
    const parentRect = parent.getBoundingClientRect()
    const offset = Math.max(0, Math.round(contentRect.left - parentRect.left))
    document.documentElement.style.setProperty('--creative-row-text-offset', `${offset}px`)
    document.documentElement.classList.add('creative-alignment-ready')
    return true
  }

  queueAlignmentUpdate(retries = 5) {
    if (retries <= 0) return
    requestAnimationFrame(() => {
      const updated = this.updateAlignmentOffset()
      if (!updated) {
        setTimeout(() => this.queueAlignmentUpdate(retries - 1), 100)
      }
    })
  }
}
