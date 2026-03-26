import { Controller } from '@hotwired/stimulus'

// Toggles parent .comments-btn visibility when badge count changes.
// Handles the case where first comment creates a badge on a previously
// hidden (no-comments) button — Turbo Streams replaces the badge span
// but doesn't update the parent button's class.
export default class extends Controller {
  static values = {
    hasComments: { type: Boolean, default: false },
  }

  connect() {
    this.toggleParentVisibility()
  }

  hasCommentsValueChanged() {
    this.toggleParentVisibility()
  }

  toggleParentVisibility() {
    const btn = this.element.closest('.comments-btn')
    if (!btn) return

    if (this.hasCommentsValue) {
      btn.classList.remove('no-comments')
    } else {
      btn.classList.add('no-comments')
    }
  }
}
