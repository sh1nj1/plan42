import { Controller } from "@hotwired/stimulus"

const MODEL_PREFIX = "paperclip/"
const ENGINE_BY_ADAPTER = { claude_local: "claude", codex_local: "codex", codex_custom: "codex_custom" }
const FAST_MODE_ADAPTERS = ["codex_local"]
const MODEL_EVENTS = ["input", "change"]

function adapterFor(model) {
  const value = (model || "").trim()
  if (!value.startsWith(MODEL_PREFIX)) return null
  return value.slice(MODEL_PREFIX.length).split("/")[0] || null
}

export default class extends Controller {
  static targets = ["vendor", "gateway", "gatewaySelect", "legacyCredential", "model",
    "runOptions", "effort", "fastMode", "fastModeCheckbox"]
  static values = { defaultModel: String }

  connect() {
    this.onModelInput = () => this.updateRunOptions()
    // A picked suggestion sets the value without an input event.
    for (const type of MODEL_EVENTS) this.modelTarget.addEventListener(type, this.onModelInput)
    this.update()
  }

  disconnect() {
    for (const type of MODEL_EVENTS) this.modelTarget.removeEventListener(type, this.onModelInput)
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
    this.updateRunOptions()
  }

  // Thinking levels differ per engine and Fast mode exists only on
  // codex_local, so both follow the model id as it is typed.
  updateRunOptions() {
    if (!this.hasRunOptionsTarget) return

    const cliProxy = this.vendorTarget.value === "cli_proxy"
    const adapter = cliProxy ? adapterFor(this.modelTarget.value) : null
    const efforts = JSON.parse(this.effortTarget.dataset.efforts || "{}")[ENGINE_BY_ADAPTER[adapter]] || []

    this.runOptionsTarget.hidden = efforts.length === 0
    Array.from(this.effortTarget.options).forEach((option) => {
      option.hidden = option.value !== "" && !efforts.includes(option.value)
    })
    if (this.effortTarget.value && !efforts.includes(this.effortTarget.value)) this.effortTarget.value = ""

    const fast = FAST_MODE_ADAPTERS.includes(adapter)
    this.fastModeTarget.hidden = !fast
  }
}
