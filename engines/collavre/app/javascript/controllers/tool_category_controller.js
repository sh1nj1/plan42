import { Controller } from "@hotwired/stimulus"

// Category header checkbox that checks/unchecks every tool in its group and
// reflects partial selection as indeterminate.
export default class extends Controller {
  static targets = [ "toggle", "tool", "count", "disclosure", "body" ]

  connect() {
    this.sync()
  }

  expand() {
    this.bodyTarget.hidden = !this.bodyTarget.hidden
    this.disclosureTarget.setAttribute("aria-expanded", String(!this.bodyTarget.hidden))
  }

  toggle() {
    const checked = this.toggleTarget.checked
    this.toolTargets.forEach((tool) => { tool.checked = checked })
    this.sync()
  }

  sync() {
    const total = this.toolTargets.length
    const selected = this.toolTargets.filter((tool) => tool.checked).length

    this.toggleTarget.checked = selected === total
    this.toggleTarget.indeterminate = selected > 0 && selected < total
    if (this.hasCountTarget) this.countTarget.textContent = String(selected)
  }
}
