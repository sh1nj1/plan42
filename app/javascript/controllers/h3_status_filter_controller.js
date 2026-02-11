import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["chip", "form", "hiddenFields"]

  toggle(event) {
    const chip = event.currentTarget
    chip.classList.toggle("active")
    this.syncHiddenFields()
    this.formTarget.requestSubmit()
  }

  syncHiddenFields() {
    // Clear existing hidden fields
    this.hiddenFieldsTarget.replaceChildren()

    // Add hidden fields for all active chips
    this.chipTargets.forEach(chip => {
      if (chip.classList.contains("active")) {
        const input = document.createElement("input")
        input.type = "hidden"
        input.name = "statuses[]"
        input.value = chip.dataset.status
        this.hiddenFieldsTarget.appendChild(input)
      }
    })
  }
}
