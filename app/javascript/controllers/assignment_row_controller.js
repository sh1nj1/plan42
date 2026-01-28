import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['input', 'submit']

  checkChanges() {
    let hasChanges = false

    this.inputTargets.forEach(input => {
      if (input.value !== input.dataset.originalValue) {
        hasChanges = true
      }
    })

    if (hasChanges) {
      this.submitTarget.removeAttribute('disabled')
    } else {
      this.submitTarget.setAttribute('disabled', 'disabled')
    }
  }
}
