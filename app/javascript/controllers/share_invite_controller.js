import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["email", "submit"]

  check() {
    const email = this.emailTarget.value
    if (!email) return
    fetch(`/users/exists?email=${encodeURIComponent(email)}`)
      .then(r => r.json())
      .then(data => {
        this.submitTarget.textContent = data.exists ? this.submitTarget.dataset.share : this.submitTarget.dataset.invite
      })
  }
}
