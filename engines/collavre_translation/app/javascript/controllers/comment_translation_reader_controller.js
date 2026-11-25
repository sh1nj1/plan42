import { Controller } from "@hotwired/stimulus"

// Shared broadcasts carry inert templates. Only this request-rendered reader
// controller can mount them, so the author/background user never sets the policy.
export default class extends Controller {
  connect() {
    this.observer = new MutationObserver(() => this.hydrate())
    this.observer.observe(document.body, { childList: true, subtree: true })
    this.hydrate()
  }

  disconnect() {
    this.observer.disconnect()
  }

  hydrate() {
    document.querySelectorAll('template[data-comment-translation-template]').forEach(template => {
      const fragment = template.content.cloneNode(true)
      fragment.firstElementChild.setAttribute('data-controller', 'comment-translation')
      template.replaceWith(fragment)
    })
  }
}
