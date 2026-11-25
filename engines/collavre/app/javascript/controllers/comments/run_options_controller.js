import { Controller } from '@hotwired/stimulus'
import CommonPopup, { elementAnchor } from '../../lib/common_popup'

// Per-message run options for CLI Proxy agents (reasoning effort).
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
  static targets = ['panel', 'toggle', 'effort']

  connect() {
    this.topicId = null
    this.mainTopicId = null
    this.handleTopicChange = this.handleTopicChange.bind(this)
    this.popup = this.element.closest('#comments-popup') || document
    this.popup.addEventListener('comments--topics:change', this.handleTopicChange)
    this.menu = new CommonPopup(this.panelTarget, {
      renderItem: (item) => item.html,
      onSelect: (item) => this.selectEffort(item.value),
      onClose: () => this.anchor?.setAttribute('aria-expanded', 'false')
    })
    this.restore()
  }

  disconnect() {
    this.menu.hide()
    this.popup.removeEventListener('comments--topics:change', this.handleTopicChange)
  }

  handleTopicChange(event) {
    this.menu.hide()
    this.topicId = event.detail?.topicId || null
    this.mainTopicId = event.detail?.mainTopicId || null
    this.restore()
  }

  // The comment form resets itself after every send. The reset event fires
  // before the fields are cleared, so the choice goes back afterwards — from
  // storage, or from the values captured here when there is no topic key.
  afterReset() {
    const current = { reasoning_effort: this.effortTarget.value }
    setTimeout(() => this.restore(current), 0)
  }

  toggle() {
    this.openFrom(this.toggleTarget)
  }

  openFrom(anchor) {
    const sameAnchor = this.anchor === anchor
    if (this.menu.isOpen()) {
      this.menu.hide()
      if (sameAnchor) return
    }
    this.anchor = anchor
    const items = Array.from(this.effortTarget.options, (option) => {
      const label = document.createElement('span')
      label.textContent = `${option.selected ? '✓ ' : ''}${option.textContent}`
      return { value: option.value, html: label.outerHTML }
    })
    this.menu.setItems(items)
    this.menu.setActiveIndex(this.effortTarget.selectedIndex)
    this.menu.showAt(elementAnchor(this.anchor))
    this.anchor.setAttribute('aria-expanded', 'true')
    this.anchor.focus()
  }

  keepOpen(event) {
    event.stopPropagation()
  }

  keydown(event) {
    if (this.menu.handleKey(event)) {
      event.preventDefault()
      event.stopPropagation()
    }
  }

  selectEffort(value) {
    this.effortTarget.value = value
    this.change()
    this.menu.hide()
    this.anchor?.focus()
  }

  change() {
    this.persist()
    this.render()
  }

  storageKey() {
    const topicId = this.topicId || this.mainTopicId
    const userId = document.body.dataset.currentUserId
    return topicId && userId ? `${STORAGE_PREFIX}${topicId}:user:${userId}` : null
  }

  persist() {
    const key = this.storageKey()
    if (!key) return
    const value = { reasoning_effort: this.effortTarget.value }
    try {
      if (value.reasoning_effort) {
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
    this.render()
  }

  render() {
    const levels = { none: 0, minimal: 1, low: 1, medium: 2, high: 3, xhigh: 4, max: 4 }
    this.toggleTarget.style.setProperty('--thinking-level', levels[this.effortTarget.value] || 0)
    this.toggleTarget.title = this.effortTarget.selectedOptions[0]?.textContent || ''
    this.toggleTarget.classList.toggle('active', Boolean(this.effortTarget.value))
  }
}
