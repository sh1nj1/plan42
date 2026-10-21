import { Controller } from '@hotwired/stimulus'

// The proposed change of a document-mode review, under the agent's reply (see
// collavre/comments/_creative_quote_review). The diff loads right away, since
// the details start open. A rejection hands the user straight to the chat
// input to tell the agent what to change next.
export default class extends Controller {
  static values = { rejectPlaceholder: String }

  connect() {
    const details = this.element.querySelector('[data-controller~="creative-history-detail"]')
    if (!details?.open) return

    requestAnimationFrame(() => {
      const detail = this.application.getControllerForElementAndIdentifier(details, 'creative-history-detail')
      detail?.load({ type: 'connect', target: details })
    })
  }

  applied(event) {
    if (event.detail?.status !== 'rejected') return

    const popup = this.element.closest('#comments-popup')
    const textarea = popup?.querySelector('[data-comments--form-target="textarea"]')
    if (!textarea) return

    if (this.rejectPlaceholderValue) textarea.placeholder = this.rejectPlaceholderValue
    textarea.focus()
  }
}
