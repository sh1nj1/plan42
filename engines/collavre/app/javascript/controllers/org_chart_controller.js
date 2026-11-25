import { updatePermission } from "../lib/permission_update"
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "toggleAllBtn" ]

  toggleAll() {
    const details = this.element.querySelectorAll("details.org-chart-group")
    const allOpen = Array.from(details).every(d => d.open)

    details.forEach(d => d.open = !allOpen)

    if (this.hasToggleAllBtnTarget) {
      const btn = this.toggleAllBtnTarget
      btn.textContent = allOpen
        ? btn.dataset.expandText || btn.textContent
        : btn.dataset.collapseText || btn.textContent
    }
  }

  updatePermission(event) {
    return updatePermission(event.target, { onFailure: () => location.reload() })
  }

}
