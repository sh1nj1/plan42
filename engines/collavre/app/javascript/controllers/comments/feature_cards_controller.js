import { Controller } from "@hotwired/stimulus"
import csrfFetch from "../../lib/api/csrf_fetch"

// Empty-chat feature discovery cards: dismiss/restore persistence and the
// "/ commands" quick action. Topic list and share modal actions are handled
// directly by their own controllers (comments--topics, share-modal) via
// data-action on the rendered buttons.
export default class extends Controller {
  static targets = ["grid", "card", "minimalTemplate"]

  dismiss(event) {
    const key = event.currentTarget.dataset.key
    if (!key) return

    const card = event.currentTarget.closest(".feature-card")
    card?.remove()

    if (this.hasGridTarget && this.gridTarget.querySelectorAll(".feature-card").length === 0) {
      this._showMinimal()
    }

    csrfFetch(`/notices/${encodeURIComponent(key)}/dismiss`, { method: "POST" }).catch(() => {})
  }

  restoreAll() {
    csrfFetch("/notices", { method: "DELETE" })
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
    const listController = popup && window.Stimulus?.getControllerForElementAndIdentifier(popup, "comments--list")
    listController?.loadInitialComments()
  }
}
