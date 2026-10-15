import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ['loading']

  connect() {
    const frame = this.element.querySelector('iframe')
    if (frame?.contentDocument?.readyState === 'complete' &&
        frame.contentDocument.URL !== 'about:blank') this.loaded()
  }

  loaded() {
    this.element.setAttribute('aria-busy', 'false')
    this.loadingTarget.hidden = true
  }
}
