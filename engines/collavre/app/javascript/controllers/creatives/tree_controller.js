import { Controller } from '@hotwired/stimulus'
import { renderCreativeTree, dispatchCreativeTreeUpdated } from '../../creatives/tree_renderer'
import { parseEmojis } from '../../utils/emoji_parser'

export default class extends Controller {
  static values = {
    url: String,
    emptyHtml: String,
  }

  connect() {
    this.abortController = null
    this.loadingIndicator = null
    this._editing = false
    this._pendingRefetch = false
    this.handleResize = this.updateAlignmentOffset.bind(this)
    this.handleTreeUpdated = () => this.queueAlignmentUpdate()
    this.handleSyncRefetch = (e) => this._handleSyncRefetch(e)
    this.handleDocSyncRefetch = (e) => this._handleSyncRefetch(e)
    this._handleEditStart = () => { this._editing = true }
    this._handleEditStop = () => {
      this._editing = false
      if (this._pendingRefetch) {
        this._pendingRefetch = false
        this.debouncedLoad()
      }
    }
    document.documentElement.classList.remove('creative-alignment-ready')
    if (!this.hasCachedContent()) {
      this.load()
    }
    this.queueAlignmentUpdate()
    window.addEventListener('resize', this.handleResize)
    this.element.addEventListener('creative-tree:updated', this.handleTreeUpdated)
    this.element.addEventListener('creative-sync:refetch', this.handleSyncRefetch)
    document.addEventListener('creative-sync:refetch', this.handleDocSyncRefetch)
    document.addEventListener('creative-editing:start', this._handleEditStart)
    document.addEventListener('creative-editing:stop', this._handleEditStop)
    this._setupArchiveToggle()
  }

  disconnect() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
    window.removeEventListener('resize', this.handleResize)
    this.element.removeEventListener('creative-tree:updated', this.handleTreeUpdated)
    this.element.removeEventListener('creative-sync:refetch', this.handleSyncRefetch)
    document.removeEventListener('creative-sync:refetch', this.handleDocSyncRefetch)
    document.removeEventListener('creative-editing:start', this._handleEditStart)
    document.removeEventListener('creative-editing:stop', this._handleEditStop)
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

  _handleSyncRefetch(event) {
    if (this._editing) {
      // While editing, skip full tree refetch (it would close the editor).
      // Row-level updates are already applied by refresh_creative_tree action.
      // Queue a full refetch for when editing ends (to update progress_html etc.)
      this._pendingRefetch = true
      return
    }
    this.debouncedLoad()
  }

  debouncedLoad() {
    if (this._debouncedLoadTimer) clearTimeout(this._debouncedLoadTimer)
    this._debouncedLoadTimer = setTimeout(() => this.load(), 300)
  }

  load() {
    if (!this.hasUrlValue) return

    if (this.abortController) {
      this.abortController.abort()
    }
    this.abortController = new AbortController()
    this.showLoadingIndicator()

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
        console.error(error)
        this.hideLoadingIndicator()
        this.showEmptyState()
      })
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
  }

  showEmptyState() {
    const html = this.hasEmptyHtmlValue ? this.emptyHtmlValue : ''
    this.element.innerHTML = html
    this.markContentLoaded()
    document.documentElement.classList.add('creative-alignment-ready')
  }

  showLoadingIndicator() {
    if (!this.loadingIndicator) {
      const indicator = document.createElement('div')
      indicator.className = 'creative-tree-loading-placeholder'
      indicator.setAttribute('role', 'status')
      indicator.setAttribute('aria-live', 'polite')
      indicator.setAttribute('aria-label', 'Loading creatives')
      indicator.innerHTML = `
        <span class="creative-loading-indicator" aria-hidden="true">
          <span class="creative-loading-dot">.</span>
          <span class="creative-loading-dot">.</span>
          <span class="creative-loading-dot">.</span>
        </span>
      `
      this.loadingIndicator = indicator
    }
    this.clearLoadedState()
    this.element.innerHTML = ''
    this.element.appendChild(this.loadingIndicator)
    this.startAnimation()
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
