import { Controller } from '@hotwired/stimulus'
import { renderCreativeTree, dispatchCreativeTreeUpdated } from '../../creatives/tree_renderer'
import { createCreativeLoadingIndicator } from '../../lib/creative_loading_indicator'

export default class extends Controller {
  static values = {
    url: String,
    emptyHtml: String,
  }

  connect() {
    this.abortController = null
    this.loadingIndicator = null
    this.handleResize = this.updateAlignmentOffset.bind(this)
    this.handleTreeUpdated = () => this.queueAlignmentUpdate()
    document.documentElement.classList.remove('creative-alignment-ready')
    if (!this.hasCachedContent()) {
      this.load()
    }
    this.queueAlignmentUpdate()
    window.addEventListener('resize', this.handleResize)
    this.element.addEventListener('creative-tree:updated', this.handleTreeUpdated)
  }

  disconnect() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
    if (this.loadingAnimator) {
      this.loadingAnimator.stop()
    }
    window.removeEventListener('resize', this.handleResize)
    this.element.removeEventListener('creative-tree:updated', this.handleTreeUpdated)
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

      const { element, animator } = createCreativeLoadingIndicator({ label: 'Loading creatives' })
      indicator.appendChild(element)
      this.loadingIndicator = indicator
      this.loadingAnimator = animator
    }
    this.clearLoadedState()
    this.element.innerHTML = ''
    this.element.appendChild(this.loadingIndicator)
    this.loadingAnimator?.start()
  }

  hideLoadingIndicator() {
    if (this.loadingIndicator && this.loadingIndicator.parentNode === this.element) {
      this.element.removeChild(this.loadingIndicator)
    }
    this.loadingAnimator?.stop()
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
