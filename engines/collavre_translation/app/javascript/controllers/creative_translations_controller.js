import { translationLocaleUrl } from "./translation_locale"
import { Controller } from "@hotwired/stimulus"
import { sanitizeDescriptionHtml } from "collavre/lib/utils/sanitize_description"
import csrfFetch from "collavre/lib/api/csrf_fetch"
import { LABEL, ROWS, PROTECTED, translationSource, translationContent, translationUrl, treeTranslation } from "./workspace_translation"


export default class extends Controller {
  static values = { base: String, original: String, translated: String }

  connect() {
    this.rows = new Map()
    this.showTranslated = true
    this.observer = new MutationObserver(() => this.scan())
    this.observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-creative-id', 'data-original-label'] })
    this.visibility = new IntersectionObserver(entries => {
      entries.filter(entry => entry.isIntersecting).forEach(entry => {
        this.visibility.unobserve(entry.target)
        this.load(entry.target)
      })
    })
    this.scan()
  }

  scan() {
    this.mountMenu()
    this.rows.forEach((state, row) => {
      if (!row.isConnected || row.dataset.creativeId !== state.id || translationSource(row) !== state.source ||
          (state.content && state.content !== translationContent(row))) this.cleanup(row, state)
    })
    document.querySelectorAll(ROWS).forEach(row => {
      if (this.rows.has(row) || !translationSource(row)) return
      this.rows.set(row, { source: translationSource(row), id: row.dataset.creativeId, abort: new AbortController() })
      this.visibility.observe(row)
    })
  }

  async load(row, retryFailed = true) {
    const state = this.rows.get(row)
    if (!state) return
    try {
      const url = translationLocaleUrl(translationUrl(this.baseValue, row))
      const request = async method => {
        const response = await csrfFetch(url, { method, signal: state.abort.signal,
          headers: { Accept: 'application/json' } })
        if (!response.ok) throw new Error('Translation unavailable')
        return response.json()
      }
      let result = await request('GET')
      if (['missing', 'pending'].includes(result.status) || (retryFailed && result.status === 'failed')) result = await request('POST')
      if (state.abort.signal.aborted || translationSource(row) !== state.source) return
      if (row.matches(LABEL)) {
        result = treeTranslation(result, state.source, row)
        if (!result) return
      } else if (sanitizeDescriptionHtml(result.original_html) !== state.source) return
      if (state.digest && state.digest !== result.source_digest) return
      state.digest = result.source_digest
      if (result.status === 'completed') this.show(row, state, JSON.parse(result.content))
      else if (['pending', 'processing', 'translating'].includes(result.status)) {
        state.delay = Math.min((state.delay || 500) * 2, 10000)
        state.timer = setTimeout(() => this.load(row, false), state.delay)
      }
    } catch { /* Leave the original visible when translation is unavailable. */ }
  }

  show(row, state, replacements) {
    const content = translationContent(row)
    if (!content || state.nodes) return
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
    state.exportHandler = event => {
      if (!state.translated || !event.target.closest('.table-download-btn')) return
      this.toggle(state)
      setTimeout(() => {
        if (!state.abort.signal.aborted && !state.translated) this.toggle(state)
      }, 0)
    }
    row.addEventListener('click', state.exportHandler, true)
    this.toggle(state, this.showTranslated)
  }

  toggle(state, translated = !state.translated) {
    state.translated = translated
    state.nodes.forEach(({ node, original, translated }) => { node.textContent = state.translated ? translated : original })

  }

  mountMenu() {
    const menu = document.getElementById('creative-overflow-menu')
    if (!menu || this.menuButton?.parentElement === menu) return
    this.menuButton?.remove()
    this.menuButton = document.createElement('button')
    this.menuButton.type = 'button'
    this.menuButton.className = 'popup-menu-item creative-translation-toggle'
    this.menuButton.addEventListener('click', () => {
      this.showTranslated = !this.showTranslated
      this.rows.forEach(state => { if (state.nodes) this.toggle(state, this.showTranslated) })
      this.updateMenu()
    })
    this.updateMenu()
    menu.append(this.menuButton)
  }

  updateMenu() {
    this.menuButton.textContent = this.showTranslated ? this.originalValue : this.translatedValue
    this.menuButton.setAttribute('aria-pressed', String(this.showTranslated))
  }

  cleanup(row, state) {
    state.abort.abort()
    clearTimeout(state.timer)
    this.visibility.unobserve(row)
    state.nodes?.forEach(({ node, original, translated }) => {
      if (node.isConnected && node.textContent === translated) node.textContent = original
    })
    if (state.exportHandler) row.removeEventListener("click", state.exportHandler, true)
    this.rows.delete(row)
  }

  disconnect() {
    this.menuButton?.remove()
    this.observer.disconnect()
    this.visibility.disconnect()
    this.rows.forEach((state, row) => this.cleanup(row, state))
  }
}
