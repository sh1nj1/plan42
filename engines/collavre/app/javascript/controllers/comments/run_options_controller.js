import { Controller } from '@hotwired/stimulus'

// Per-message run options for CLI Proxy agents (model, reasoning effort).
// The fields sit inside the comment form, so FormData sends them with every
// message. A choice is remembered per topic in localStorage and never touches
// the agent's own defaults. The full-message view (no topic selected) posts to
// the creative's main topic, so it shares that topic's choice; with no topic
// at all nothing is remembered, since a shared key would leak across creatives.
export const STORAGE_PREFIX = 'collavre:agent-run-options:topic:'

// A regular submit sends the panel with FormData(form); sends that build their
// own FormData (question quotes) copy the fields over with this.
export function appendRunOptions(form, formData) {
  new FormData(form).forEach((value, name) => {
    if (name.startsWith('comment[agent_run_options]')) formData.append(name, value)
  })
}

export default class extends Controller {
  static targets = ['panel', 'toggle', 'effort', 'model']

  connect() {
    this.topicId = null
    this.mainTopicId = null
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
    this.mainTopicId = event.detail?.mainTopicId || null
    this.restore()
  }

  // The comment form resets itself after every send. The reset event fires
  // before the fields are cleared, so the choice goes back afterwards — from
  // storage, or from the values captured here when there is no topic key.
  afterReset() {
    const current = { reasoning_effort: this.effortTarget.value, model: this.modelTarget.value.trim() }
    setTimeout(() => this.restore(current), 0)
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
    const topicId = this.topicId || this.mainTopicId
    return topicId ? `${STORAGE_PREFIX}${topicId}` : null
  }

  persist() {
    const key = this.storageKey()
    if (!key) return
    const value = { reasoning_effort: this.effortTarget.value, model: this.modelTarget.value.trim() }
    try {
      if (value.reasoning_effort || value.model) {
        localStorage.setItem(key, JSON.stringify(value))
      } else {
        localStorage.removeItem(key)
      }
    } catch (_error) {
      // Storage may be unavailable (private mode); the choice still applies
      // to the messages sent from this page.
    }
  }

  restore(unkeyed = {}) {
    const key = this.storageKey()
    let stored = unkeyed
    try {
      if (key) stored = JSON.parse(localStorage.getItem(key) || '{}') || {}
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
