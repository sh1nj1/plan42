import { Controller } from "@hotwired/stimulus"

// Shared broadcasts carry inert templates. Only this request-rendered reader
// controller can mount them, so the author/background user never sets the policy.
// Reader-gated templates follow this reader's preference; when it is off they stay
// inert, because the endpoint would only answer 403 for each visible comment.
export default class extends Controller {
  static values = { enabled: { type: Boolean, default: true } }

  connect() {
    this.observer = new MutationObserver(() => this.hydrate())
    this.observer.observe(document.body, { childList: true, subtree: true })
    this.hydrate()
  }

  disconnect() {
    this.observer.disconnect()
  }

  hydrate() {
    const gated = this.enabledValue ? '' : ':not([data-comment-translation-reader-gated])'
    document.querySelectorAll(`template[data-comment-translation-template]${gated}`).forEach(template => {
      const fragment = template.content.cloneNode(true)
      fragment.firstElementChild.setAttribute('data-controller', 'comment-translation')
      template.replaceWith(fragment)
    })
  }
}
