import { Controller } from "@hotwired/stimulus"
import csrfFetch from "collavre/lib/api/csrf_fetch"
import { renderCommentMarkdown, renderMermaidDiagrams } from "collavre/lib/utils/markdown"

export default class extends Controller {
  static targets = ["toggle", "content"]
  static values = { url: String, digest: String, loading: String, translated: String,
    original: String, showTranslation: String }

  connect() {
    this.abort = new AbortController()
    this.original = this.element.closest('.comment-item')?.querySelector('[data-comment-target="content"]')
    if (!this.original) return
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
    clearTimeout(this.timer)
    if (this.original) this.original.hidden = false
  }

  async load() {
    try {
      if (!this.mutations) {
        this.mutations = new MutationObserver(() => {
          this.abort.abort()
          clearTimeout(this.timer)
          this.restoreOriginal()
        })
        this.mutations.observe(this.original, { childList: true, subtree: true, characterData: true })
      }
      let response = await this.request('GET')
      if (['missing', 'pending'].includes(response.status)) response = await this.request('POST')
      this.handleResponse(response)
    } catch {
      this.restoreOriginal()
    }
  }

  async request(method) {
    const response = await csrfFetch(this.urlValue, { method, signal: this.abort.signal,
      headers: { Accept: 'application/json' } })
    if (!response.ok) throw new Error('Translation unavailable')
    return response.json()
  }

  handleResponse(response) {
    if (this.abort.signal.aborted || response.source_digest !== this.digestValue) return this.restoreOriginal()
    if (response.status === 'completed') return this.show(response.content)
    if (['pending', 'processing', 'translating'].includes(response.status)) {
      this.startedAt ||= Date.now()
      if (Date.now() - this.startedAt > 120000) return this.restoreOriginal()
      this.toggleTarget.hidden = false
      this.toggleTarget.disabled = true
      this.toggleTarget.textContent = this.loadingValue
      this.timer = setTimeout(() => this.load(), 2000)
    } else {
      this.restoreOriginal()
    }
  }

  show(content) {
    if (!content) return this.restoreOriginal()
    this.contentTarget.innerHTML = renderCommentMarkdown(content)
    this.contentTarget.classList.add('comment-content', 'comment-translation-content')
    this.showingTranslation = true
    this.toggleTarget.hidden = false
    this.toggleTarget.disabled = false
    this.updateVisibility()
    renderMermaidDiagrams(this.contentTarget)
  }

  toggle() {
    this.showingTranslation = !this.showingTranslation
    this.updateVisibility()
  }

  updateVisibility() {
    this.original.hidden = this.showingTranslation
    this.contentTarget.hidden = !this.showingTranslation
    this.toggleTarget.textContent = this.showingTranslation
      ? `${this.translatedValue} · ${this.originalValue}` : this.showTranslationValue
    this.toggleTarget.setAttribute('aria-pressed', String(this.showingTranslation))
  }

  restoreOriginal() {
    this.mutations?.disconnect()
    if (this.original) this.original.hidden = false
    this.contentTarget.hidden = true
    this.contentTarget.replaceChildren()
    this.toggleTarget.hidden = true
  }
}
