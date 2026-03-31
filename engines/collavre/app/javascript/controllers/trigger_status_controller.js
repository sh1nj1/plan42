import { Controller } from "@hotwired/stimulus"
import csrfFetch from "../lib/api/csrf_fetch"

export default class extends Controller {
  static targets = ["toggleBtn", "actionBtn"]
  static values = {
    creativeId: Number,
    role: String,
    state: String
  }

  async toggleContainer() {
    const btn = this.toggleBtnTarget
    const isActive = btn.classList.contains("trigger-container-active")
    const newState = !isActive

    // Optimistic update
    btn.classList.toggle("trigger-container-active", newState)

    try {
      const response = await csrfFetch(`/creatives/${this.creativeIdValue}/trigger_action`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "toggle_container", enabled: newState })
      })

      if (!response.ok) {
        btn.classList.toggle("trigger-container-active", !newState)
      }
    } catch (e) {
      console.error("Failed to toggle container trigger", e)
      btn.classList.toggle("trigger-container-active", !newState)
    }
  }

  async pause() {
    await this._performAction("pause")
  }

  async resume() {
    await this._performAction("resume")
  }

  async restart() {
    await this._performAction("restart")
  }

  async _performAction(actionName) {
    try {
      const response = await csrfFetch(`/creatives/${this.creativeIdValue}/trigger_action`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: actionName })
      })

      if (response.ok) {
        // Reload the page to reflect the new state
        // TODO: Replace with Turbo Stream update when available
        window.location.reload()
      }
    } catch (e) {
      console.error(`Failed to ${actionName} trigger`, e)
    }
  }
}
