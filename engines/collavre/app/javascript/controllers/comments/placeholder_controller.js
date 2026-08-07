import { Controller } from "@hotwired/stimulus"

// Shared behaviour for every "the list is empty" placeholder rendered inside
// #comments-list (the discovery cards and the no-search-results notice). The
// local submit path clears them itself
// (comments--form#removePlaceholder), but a comment written by another
// participant arrives as a Turbo Stream append straight into #comments-list
// (Comment#broadcast_create) and touches nothing else. Without this, an
// "empty" message keeps sitting above a live conversation until a reload.
export default class extends Controller {
  connect() {
    const list = this.element.parentElement
    if (!list) return

    this._listObserver = new MutationObserver((mutations) => {
      // Match .comment-item rather than "any added node" so the placeholder
      // stays put when something else touches the list.
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
}
