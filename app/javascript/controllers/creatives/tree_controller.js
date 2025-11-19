import { Controller } from '@hotwired/stimulus'
import { renderCreativeTree, dispatchCreativeTreeUpdated } from '../../creatives/tree_renderer'

export default class extends Controller {
  static values = {
    url: String,
    emptyHtml: String,
  }

  connect() {
    this.abortController = null
    this.loadingIndicator = null
    this.load()
  }

  disconnect() {
    if (this.abortController) {
      this.abortController.abort()
      this.abortController = null
    }
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
    dispatchCreativeTreeUpdated(this.element)
  }

  showEmptyState() {
    const html = this.hasEmptyHtmlValue ? this.emptyHtmlValue : ''
    this.element.innerHTML = html
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
    this.element.innerHTML = ''
    this.element.appendChild(this.loadingIndicator)
  }

  hideLoadingIndicator() {
    if (this.loadingIndicator && this.loadingIndicator.parentNode === this.element) {
      this.element.removeChild(this.loadingIndicator)
    }
  }
}
