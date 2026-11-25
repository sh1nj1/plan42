import { Controller } from "@hotwired/stimulus"
import csrfFetch from "../lib/api/csrf_fetch"

export default class extends Controller {
  static targets = ["result"]
  static values = { checking: String, success: String, failed: String }

  async check(event) {
    const button = event.currentTarget
    const result = button.parentElement.querySelector("[data-gateway-check-target='result']")
    button.disabled = true
    result.textContent = this.checkingValue

    try {
      const response = await csrfFetch(event.params.url, {
        method: "POST",
        headers: { Accept: "application/json" }
      })
      const data = await response.json()
      if (data.ok && data.identity_verified === false) {
        result.textContent = `${this.successValue}: ${data.warning || ""}`
      } else if (data.ok) {
        result.textContent = `${this.successValue} (${(data.engines || []).join(", ")})`
      } else {
        result.textContent = `${this.failedValue}: ${data.error || ""}`
      }
    } catch (_error) {
      result.textContent = this.failedValue
    } finally {
      button.disabled = false
    }
  }

}
