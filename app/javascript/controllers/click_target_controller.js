import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static values = { id: String }

  trigger(event) {
    event.preventDefault()
    const targetId = this.idValue
    if (!targetId) return
    const target = document.getElementById(targetId)
    target?.click()
  }
}
