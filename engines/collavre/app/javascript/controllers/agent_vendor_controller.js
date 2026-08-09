import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["vendor", "gateway", "gatewaySelect", "legacyCredential", "model"]
  static values = { defaultModel: String }

  connect() {
    this.update()
  }

  update() {
    const cliProxy = this.vendorTarget.value === "cli_proxy"

    this.gatewayTarget.hidden = !cliProxy
    this.gatewaySelectTarget.disabled = !cliProxy
    this.gatewaySelectTarget.required = cliProxy
    this.legacyCredentialTargets.forEach((element) => { element.hidden = cliProxy })

    if (cliProxy && !this.modelTarget.value.trim()) {
      this.modelTarget.value = this.defaultModelValue
    }
  }
}
