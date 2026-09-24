import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../lib/api/csrf_fetch'

// Fetch on each open so other avatars and tabs cannot leave stale defaults.
export default class extends Controller {
  static values = { url: String }

  async load() {
    if (this.loading || this.saving) return
    this.element.querySelector('.comment-agent-model-editor')?.remove()
    this.loading = true
    try {
      const response = await csrfFetch(this.urlValue, { headers: { Accept: 'text/html' } })
      if (response.ok && !response.redirected) this.renderEditor(await response.text())
    } catch (_error) {
      // The menu remains usable; reopening retries loading the editor.
    } finally {
      this.loading = false
    }
  }

  get editor() {
    let editor = this.element.querySelector('.comment-agent-model-editor')
    if (!editor) {
      editor = document.createElement('div')
      editor.className = 'comment-agent-model-editor'
      editor.dataset.action = 'click->comment-agent-model#keepOpen'
      this.element.querySelector('[data-popup-menu-target="menu"]').appendChild(editor)
    }
    return editor
  }

  renderEditor(html) {
    this.editor.innerHTML = html
    this.runOptions?.render()
    const popup = this.application.getControllerForElementAndIdentifier(this.element, 'popup-menu')
    if (popup?.isOpen()) popup.place()
  }

  get runOptions() {
    const form = this.element.closest('#comments-popup')?.querySelector('[data-controller~="comments--run-options"]')
    return form && this.application.getControllerForElementAndIdentifier(form, 'comments--run-options')
  }

  thinking(event) {
    event.preventDefault()
    event.stopPropagation()
    this.runOptions?.openFrom(event.currentTarget)
  }

  thinkingKeydown(event) {
    this.runOptions?.keydown(event)
  }

  keepOpen(event) {
    event.stopPropagation()
  }

  showError(form) {
    form.querySelector('[role="status"]').textContent = form.dataset.error
  }

  async save(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.saving) return
    this.saving = true
    const form = event.target
    const button = form.querySelector('[type="submit"]')
    button.disabled = true
    try {
      const response = await csrfFetch(this.urlValue, {
        method: 'PATCH', body: new FormData(form),
        headers: { Accept: 'text/html' }
      })
      if (!response.redirected && (response.ok || response.status === 422)) this.renderEditor(await response.text())
      else this.showError(form)
    } catch (_error) {
      this.showError(form)
    } finally {
      this.saving = false
      button.disabled = false
    }
  }
}
