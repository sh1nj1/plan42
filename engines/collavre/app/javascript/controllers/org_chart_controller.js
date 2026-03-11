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
    const select = event.target
    const url = select.dataset.updateUrl
    const permission = select.value
    const originalClass = select.className

    // Update visual class immediately
    select.className = select.className.replace(/org-chart-permission-\w+/g, "")
    select.classList.add("org-chart-permission-select", `org-chart-permission-${permission}`)

    fetch(url, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content,
        "Accept": "application/json"
      },
      body: JSON.stringify({ permission })
    }).then(response => {
      if (!response.ok) throw new Error("Failed")
    }).catch(() => {
      select.className = originalClass
      location.reload()
    })
  }

}
