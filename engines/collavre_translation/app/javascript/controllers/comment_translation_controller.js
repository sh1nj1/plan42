import { Controller } from "@hotwired/stimulus"
import { addTableDownloadButtons } from "collavre/lib/utils/table_download"
import csrfFetch from "collavre/lib/api/csrf_fetch"
import { renderCommentMarkdown, renderMermaidDiagrams } from "collavre/lib/utils/markdown"

export default class extends Controller {
  static targets = ["toggle", "content"]
  static values = { url: String, digest: String, loading: String,
    original: String, showTranslation: String, translate: String }

  connect() {
    this.abort = new AbortController()
    this.original = this.element.closest('.comment-item')?.querySelector('[data-comment-target="content"]')
    if (!this.original) return
    const actions = this.element.closest('.comment-item').querySelector('.comment-action-container')
    const controls = this.toggleTarget.parentElement
    if (actions && typeof ResizeObserver !== 'undefined') {
      this.actionResize = new ResizeObserver(() => {
        controls.style.right = `${actions.getBoundingClientRect().width + 8}px`
      })
      this.actionResize.observe(actions)
    }
    this.observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) {
        this.observer.disconnect()
        this.load()
      }
    })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.abort?.abort()
    this.observer?.disconnect()
    this.mutations?.disconnect()
    this.actionResize?.disconnect()
    clearTimeout(this.timer)
    if (this.original) this.original.hidden = false
  }

  async load(retry = false) {
    let response
    try {
      if (!this.mutations) {
        this.mutations = new MutationObserver(records => {
          if (records.every(record => {
            const target = record.target.nodeType === Node.ELEMENT_NODE ? record.target : record.target.parentElement
            return target?.closest('.mermaid-chart')
          })) return
          this.abort.abort()
          clearTimeout(this.timer)
          this.restoreOriginal()
        })
        this.mutations.observe(this.original, { childList: true, subtree: true, characterData: true })
      }
      response = await this.request(retry ? 'POST' : 'GET')
      if (['missing', 'pending'].includes(response.status)) response = await this.request('POST')
    } catch (error) {
      return error.retryable ? this.showRetry() : this.restoreOriginal()
    }
    try {
      this.handleResponse(response)
    } catch {
      this.restoreOriginal()
    }
  }

  async request(method) {
    let response
    try {
      response = await csrfFetch(this.urlValue, { method, signal: this.abort.signal,
        headers: { Accept: 'application/json' } })
    } catch (error) {
      error.retryable = error.name !== 'AbortError'
      throw error
    }
    if (!response.ok) {
      const error = new Error('Translation unavailable')
      error.retryable = response.status >= 500 && response.status !== 503
      throw error
    }
    return response.json()
  }

  handleResponse(response) {
    if (this.abort.signal.aborted || response.source_digest !== this.digestValue) return this.restoreOriginal()
    this.retryAvailable = false
    if (response.status === 'failed') return this.showRetry()
    if (response.status === 'completed') return this.show(response.content)
    if (['pending', 'processing', 'translating'].includes(response.status)) {
      this.toggleTarget.hidden = false
      this.toggleTarget.disabled = true
      this.setToggleLabel(this.loadingValue)
      this.pollDelay = Math.min((this.pollDelay || 1000) * 2, 10000)
      this.timer = setTimeout(() => this.load(), this.pollDelay)
    } else {
      this.restoreOriginal()
    }
  }

  show(content) {
    if (!content) return this.restoreOriginal()
    this.contentTarget.innerHTML = renderCommentMarkdown(content)
    this.contentTarget.dataset.rendered = 'true'
    this.contentTarget.classList.add('comment-content', 'comment-translation-content')
    this.showingTranslation = true
    this.toggleTarget.hidden = false
    this.toggleTarget.disabled = false
    this.updateVisibility()
    addTableDownloadButtons(this.contentTarget)
    renderMermaidDiagrams(this.contentTarget)
  }

  toggle() {
    if (this.retryAvailable) {
      this.retryAvailable = false
      this.pollDelay = 0
      this.toggleTarget.disabled = true
      this.setToggleLabel(this.loadingValue)
      return this.load(true)
    }
    this.showingTranslation = !this.showingTranslation
    this.updateVisibility()
  }

  updateVisibility() {
    this.original.hidden = this.showingTranslation
    this.contentTarget.hidden = !this.showingTranslation
    this.setToggleLabel(this.showingTranslation ? this.originalValue : this.showTranslationValue)
    this.toggleTarget.setAttribute('aria-pressed', String(this.showingTranslation))
  }

  showRetry() {
    if (this.abort.signal.aborted) return this.restoreOriginal()
    this.restoreOriginal()
    this.retryAvailable = true
    this.toggleTarget.hidden = false
    this.toggleTarget.disabled = false
    this.setToggleLabel(this.translateValue)
    this.toggleTarget.setAttribute('aria-pressed', 'false')
  }

  setToggleLabel(label) {
    this.toggleTarget.textContent = label
    this.toggleTarget.title = label
    this.toggleTarget.setAttribute('aria-label', label)
  }

  restoreOriginal() {
    this.retryAvailable = false
    this.mutations?.disconnect()
    this.mutations = null
    if (this.original) this.original.hidden = false
    this.contentTarget.hidden = true
    this.contentTarget.replaceChildren()
    this.toggleTarget.hidden = true
    this.toggleTarget.disabled = false
    this.toggleTarget.removeAttribute('aria-pressed')
  }
}
