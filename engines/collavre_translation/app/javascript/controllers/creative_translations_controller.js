import { Controller } from "@hotwired/stimulus"
import { sanitizeDescriptionHtml } from "collavre/lib/utils/sanitize_description"
import csrfFetch from "collavre/lib/api/csrf_fetch"

const PROTECTED = 'pre, code, script, style, textarea, .mention, [data-mention], [data-lexical-mention], [contenteditable], [data-ppt-slide]'

export default class extends Controller {
  static values = { base: String, original: String, translated: String }

  connect() {
    this.rows = new Map()
    this.observer = new MutationObserver(() => this.scan())
    this.observer.observe(document.body, { childList: true, subtree: true })
    this.visibility = new IntersectionObserver(entries => {
      entries.filter(entry => entry.isIntersecting).forEach(entry => {
        this.visibility.unobserve(entry.target)
        this.load(entry.target)
      })
    })
    this.scan()
  }

  scan() {
    this.rows.forEach((state, row) => {
      if (!row.isConnected || row.descriptionHtml !== state.source ||
          (state.content && state.content !== row.querySelector(".creative-content, .creative-title-content"))) this.cleanup(row, state)
    })
    document.querySelectorAll('creative-tree-row[creative-id]').forEach(row => {
      if (this.rows.has(row) || !row.descriptionHtml) return
      this.rows.set(row, { source: row.descriptionHtml, abort: new AbortController() })
      this.visibility.observe(row)
    })
  }

  async load(row) {
    const state = this.rows.get(row)
    if (!state) return
    try {
      const url = this.baseValue.replace('__ID__', row.getAttribute('creative-id'))
      const request = async method => {
        const response = await csrfFetch(url, { method, signal: state.abort.signal,
          headers: { Accept: 'application/json' } })
        if (!response.ok) throw new Error('Translation unavailable')
        return response.json()
      }
      let result = await request('GET')
      if (['missing', 'pending'].includes(result.status)) result = await request('POST')
      if (state.abort.signal.aborted || row.descriptionHtml !== state.source) return
      if (sanitizeDescriptionHtml(result.original_html) !== state.source) return
      if (state.digest && state.digest !== result.source_digest) return
      state.digest = result.source_digest
      if (result.status === 'completed') this.show(row, state, JSON.parse(result.content))
      else if (['pending', 'processing', 'translating'].includes(result.status)) {
        state.delay = Math.min((state.delay || 500) * 2, 10000)
        state.timer = setTimeout(() => this.load(row), state.delay)
      }
    } catch { /* Leave the original visible when translation is unavailable. */ }
  }

  show(row, state, replacements) {
    const content = row.querySelector('.creative-content, .creative-title-content')
    if (!content || state.button) return
    state.content = content
    const translations = new Map(replacements.map(pair => [pair.original, pair.translated]))
    state.nodes = []
    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT)
    while (walker.nextNode()) {
      const node = walker.currentNode
      if (!node.parentElement.closest(PROTECTED) && translations.has(node.textContent)) {
        state.nodes.push({ node, original: node.textContent, translated: translations.get(node.textContent) })
      }
    }
    if (!state.nodes.length) return
    state.button = document.createElement('button')
    state.button.type = 'button'
    state.button.className = 'creative-action-btn creative-translation-toggle'
    state.button.addEventListener('click', event => {
      event.stopPropagation()
      this.toggle(state)
    })
    state.exportHandler = event => {
      if (!state.translated || !event.target.closest('.table-download-btn')) return
      this.toggle(state)
      queueMicrotask(() => {
        if (!state.abort.signal.aborted && !state.translated) this.toggle(state)
      })
    }
    row.addEventListener('click', state.exportHandler, true)
    content.after(state.button)
    this.toggle(state)
  }

  toggle(state) {
    state.translated = !state.translated
    state.nodes.forEach(({ node, original, translated }) => { node.textContent = state.translated ? translated : original })
    state.button.textContent = state.translated ? this.originalValue : this.translatedValue
    state.button.setAttribute('aria-pressed', String(state.translated))
  }

  cleanup(row, state) {
    state.abort.abort()
    clearTimeout(state.timer)
    this.visibility.unobserve(row)
    state.nodes?.forEach(({ node, original }) => { if (node.isConnected) node.textContent = original })
    if (state.exportHandler) row.removeEventListener("click", state.exportHandler, true)
    state.button?.remove()
    this.rows.delete(row)
  }

  disconnect() {
    this.observer.disconnect()
    this.visibility.disconnect()
    this.rows.forEach((state, row) => this.cleanup(row, state))
  }
}
