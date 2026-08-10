import { Controller } from "@hotwired/stimulus"
import csrfFetch from "../lib/api/csrf_fetch"

// The browser handles consent and a short-lived registration grant only. The
// Tauri command keeps proxy secrets in Keychain and posts them directly to the
// local Rails sidecar, so no secret is exposed to the DOM.
export default class extends Controller {
  static targets = ["consent", "submit", "error"]
  static values = { tokenUrl: String, nextUrl: String, unavailable: String, failed: String }

  toggle() {
    this.submitTarget.disabled = !this.consentTarget.checked
  }

  async install() {
    this.errorTarget.hidden = true
    this.submitTarget.disabled = true

    try {
      const invoke = window.__TAURI__?.core?.invoke
      if (!invoke) throw new Error(this.unavailableValue)

      const response = await csrfFetch(this.tokenUrlValue, { method: "POST" })
      if (!response.ok) throw new Error(this.failedValue)
      const { token } = await response.json()
      const result = await invoke("desktop_proxy_complete_setup", {
        registrationToken: token,
        serverPort: Number(window.location.port),
      })
      const query = new URLSearchParams()
      for (const adapter of result.adapters || []) query.set(adapter, "1")
      window.location.assign(`${this.nextUrlValue}?${query.toString()}`)
    } catch (error) {
      this.errorTarget.textContent = error?.message || this.failedValue
      this.errorTarget.hidden = false
      this.submitTarget.disabled = !this.consentTarget.checked
    }
  }
}
