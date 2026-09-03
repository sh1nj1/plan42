import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static values = { timeout: { type: Number, default: 30000 } }

  connect() {
    window.dispatchEvent(new CustomEvent('collavre:creative-drop-complete'))
    this.timer = window.setTimeout(() => this.dismiss(), this.timeoutValue)
  }

  disconnect() {
    window.clearTimeout(this.timer)
  }

  dismiss() {
    this.element.remove()
  }
}
