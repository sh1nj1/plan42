import { Controller } from '@hotwired/stimulus'

// Per-message run options for CLI Proxy agents (model, reasoning effort).
// The fields sit inside the comment form, so FormData sends them with every
// message. A choice is remembered per topic in localStorage and never touches
// the agent's own defaults.
export const STORAGE_PREFIX = 'collavre:agent-run-options:topic:'

export default class extends Controller {
  static targets = ['panel', 'toggle', 'effort', 'model']

  connect() {
    this.topicId = null
    this.handleTopicChange = this.handleTopicChange.bind(this)
    this.popup = this.element.closest('#comments-popup') || document
    this.popup.addEventListener('comments--topics:change', this.handleTopicChange)
    this.restore()
  }

  disconnect() {
    this.popup.removeEventListener('comments--topics:change', this.handleTopicChange)
  }

  handleTopicChange(event) {
    this.topicId = event.detail?.topicId || null
    this.restore()
  }

  // The comment form resets itself after every send. The reset event fires
  // before the fields are cleared, so the stored choice goes back afterwards.
  afterReset() {
    setTimeout(() => this.restore(), 0)
  }

  toggle() {
    const open = this.panelTarget.hidden
    this.panelTarget.hidden = !open
    this.toggleTarget.setAttribute('aria-expanded', String(open))
  }

  change() {
    this.persist()
    this.render()
  }

  reset() {
    this.effortTarget.value = ''
    this.modelTarget.value = ''
    this.change()
  }

  storageKey() {
    return `${STORAGE_PREFIX}${this.topicId || 'main'}`
  }

  persist() {
    const value = { reasoning_effort: this.effortTarget.value, model: this.modelTarget.value.trim() }
    try {
      if (value.reasoning_effort || value.model) {
        localStorage.setItem(this.storageKey(), JSON.stringify(value))
      } else {
        localStorage.removeItem(this.storageKey())
      }
    } catch (_error) {
      // Storage may be unavailable (private mode); the choice still applies
      // to the messages sent from this page.
    }
  }

  restore() {
    let stored = {}
    try {
      stored = JSON.parse(localStorage.getItem(this.storageKey()) || '{}') || {}
    } catch (_error) {
      stored = {}
    }
    this.effortTarget.value = stored.reasoning_effort || ''
    // A stored effort the <select> no longer offers leaves no option selected.
    if (this.effortTarget.value !== (stored.reasoning_effort || '')) this.effortTarget.value = ''
    this.modelTarget.value = stored.model || ''
    this.render()
  }

  render() {
    const active = Boolean(this.effortTarget.value || this.modelTarget.value.trim())
    this.toggleTarget.classList.toggle('active', active)
  }
}
