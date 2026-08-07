import { Controller } from "@hotwired/stimulus"
import csrfFetch from "../../lib/api/csrf_fetch"

// Empty-chat feature discovery cards: dismiss/restore persistence and the
// "/ commands" quick action. Topic list and share modal actions are handled
// directly by their own controllers (comments--topics, share-modal) via
// data-action on the rendered buttons.
export default class extends Controller {
  static targets = ["grid", "card", "minimalTemplate"]

  initialize() {
    // Dismissals are optimistic: the card disappears immediately and the POST
    // is sent in the background. Dismissing the last card reveals the restore
    // button right away, so a fast user can click restore while a dismissal is
    // still in flight. Track them so restoreAll can wait, otherwise a late
    // dismissal lands after the DELETE and silently re-hides that card.
    this._pendingDismissals = new Set()
  }

  dismiss(event) {
    const key = event.currentTarget.dataset.key
    if (!key) return

    const card = event.currentTarget.closest(".feature-card")
    card?.remove()

    if (this.hasGridTarget && this.gridTarget.querySelectorAll(".feature-card").length === 0) {
      this._showMinimal()
    }

    const request = csrfFetch(`/notices/${encodeURIComponent(key)}/dismiss`, { method: "POST" }).catch(() => {})
    this._pendingDismissals.add(request)
    request.finally(() => this._pendingDismissals.delete(request))
  }

  restoreAll() {
    return Promise.all([ ...this._pendingDismissals ])
      .then(() => csrfFetch("/notices", { method: "DELETE" }))
      .then((response) => {
        if (!response.ok) return
        this._reloadComments()
      })
      .catch(() => {})
  }

  openCommandMenu() {
    const textarea = document.querySelector("#new-comment-form textarea")
    if (!textarea) return

    textarea.focus()

    // Don't clobber a draft the user already started typing — the command
    // menu only opens for "/" at the very start of the message anyway, so
    // there's nothing useful to trigger once there's other content.
    if (textarea.value.trim().length > 0) {
      textarea.setSelectionRange(textarea.value.length, textarea.value.length)
      return
    }

    textarea.value = "/"
    textarea.setSelectionRange(1, 1)
    textarea.dispatchEvent(new Event("input", { bubbles: true }))
  }

  _showMinimal() {
    if (!this.hasMinimalTemplateTarget) return
    this.element.innerHTML = this.minimalTemplateTarget.innerHTML
  }

  _reloadComments() {
    const popup = this.element.closest("#comments-popup")
    // Resolve through this controller's own Stimulus application rather than a
    // `window.Stimulus` global — embedding hosts register controllers on a local
    // application (see engines/collavre/docs/installation.md) and never expose it.
    const listController = popup && this.application.getControllerForElementAndIdentifier(popup, "comments--list")
    listController?.loadInitialComments()
  }
}
