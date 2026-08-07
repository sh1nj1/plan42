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

  connect() {
    // The local submit path clears this placeholder itself
    // (comments--form#removePlaceholder), but a comment written by another
    // participant arrives as a Turbo Stream append straight into
    // #comments-list (Comment#broadcast_create) and touches nothing else.
    // Without this, the whole discovery grid — including advice for starting a
    // conversation — keeps sitting above a live one until the list reloads.
    const list = this.element.parentElement
    if (!list) return

    this._listObserver = new MutationObserver((mutations) => {
      const commentArrived = mutations.some((mutation) =>
        [ ...mutation.addedNodes ].some((node) => node.nodeType === 1 && node.matches(".comment-item")),
      )
      if (commentArrived) this.element.remove()
    })
    this._listObserver.observe(list, { childList: true })
  }

  disconnect() {
    this._listObserver?.disconnect()
    this._listObserver = null
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

    // The menu only triggers on a "/" token at the very start of the message
    // (see modules/command_menu.js), so opening it means putting a "/" there.
    // Prepend instead of overwriting so a draft the user already started is
    // kept — identical to them moving the caret home and typing "/".
    const hadSlash = textarea.value.startsWith("/")
    if (!hadSlash) textarea.value = `/${textarea.value}`

    // The menu filters on the text between "/" and the caret. Park the caret
    // right after the "/" we injected so the full list shows; if the user had
    // already typed their own "/to", keep their partial query and pre-filter.
    const caret = hadSlash ? textarea.value.match(/^\/[^\s/]*/)[0].length : 1
    textarea.setSelectionRange(caret, caret)
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
