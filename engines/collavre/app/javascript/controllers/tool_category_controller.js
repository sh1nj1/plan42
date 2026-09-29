import { Controller } from "@hotwired/stimulus"
import { CHEVRON_COLLAPSED, CHEVRON_EXPANDED } from "../utils/chevron_icons"

// Category header checkbox that checks/unchecks every tool in its group and
// reflects partial selection as indeterminate.
export default class extends Controller {
  static targets = [ "toggle", "tool", "count", "disclosure", "body" ]

  connect() {
    this.sync()
    this.renderDisclosure()
  }

  expand() {
    this.bodyTarget.hidden = !this.bodyTarget.hidden
    this.renderDisclosure()
  }

  renderDisclosure() {
    const expanded = !this.bodyTarget.hidden
    this.disclosureTarget.setAttribute("aria-expanded", String(expanded))
    this.disclosureTarget.innerHTML = expanded ? CHEVRON_EXPANDED : CHEVRON_COLLAPSED
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
