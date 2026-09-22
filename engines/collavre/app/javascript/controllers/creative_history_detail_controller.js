import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../lib/api/csrf_fetch'

export default class extends Controller {
  static targets = ['content', 'loading', 'error']
  static values = { url: String }

  disconnect() {
    this.requestController?.abort()
  }

  async load(event) {
    if (event.type === 'toggle' && event.target !== this.element) return
    if (!this.element.open || this.loaded || this.loading) return

    this.loading = true
    this.loadingTarget.hidden = false
    this.errorTarget.hidden = true
    this.requestController = new AbortController()
    try {
      await this.fetchDetail(this.requestController.signal)
    } catch (error) {
      if (error.name !== 'AbortError') this.errorTarget.hidden = false
    } finally {
      this.loading = false
      this.loadingTarget.hidden = true
    }
  }

  async fetchDetail(signal) {
    const response = await csrfFetch(this.urlValue, {
      headers: { Accept: 'text/html' }, cache: 'no-store', redirect: 'error', signal,
    })
    if (!response.ok) throw new Error('History detail request failed')
    const html = await response.text()
    if (signal.aborted) return

    this.contentTarget.innerHTML = html
    this.loaded = true
  }
}
