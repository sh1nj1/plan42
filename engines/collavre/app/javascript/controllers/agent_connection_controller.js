import AgentAuthController from "./agent_auth_controller"

export default class extends AgentAuthController {
  static targets = ["engines", "provision", "session", "error", "manifest"]
  static values = {
    statusUrl: String,
    sessionUrl: String,
    sessionDetailUrl: String,
    syncUrl: String,
    approveUrl: String,
    deleteUrl: String,
    loading: String,
    login: String,
    submit: String,
    baseUrlLabel: String,
    baseUrlHelp: String,
    cancel: String,
    openUrl: String,
    approve: String,
    revoke: String,
    error: String,
    manifestUnregistered: String,
    lastError: String,
    statusLabels: Object,
    itemTypeLabels: Object
  }

  async refresh() {
    this.hideError()
    try {
      const data = await this.request(this.statusUrlValue)
      const engines = data.engines || []
      this.baseUrlFlows = new Map(engines.map((engine) => [engine.engine, engine.base_url_flows || []]))
      this.renderEngines(engines)
      if (this.hasProvisionTarget) this.renderProvision(data.provision || {})
      if (data.resumed) this.enginesTarget.replaceChildren(document.createTextNode(this.resumedValue))
      else if (data.authorized && this.hasResumeUrlValue) await this.authorized()
    } catch (error) {
      this.showError(error.message)
    }
  }

  async sync() {
    try {
      const data = await this.request(this.syncUrlValue, { method: "POST" })
      this.renderProvision(data)
    } catch (error) {
      this.showError(error.message)
    }
  }

  async approveItem(event) {
    await this.mutateProvisionItem(event, this.approveUrlValue, "POST")
  }

  async revokeItem(event) {
    await this.mutateProvisionItem(event, this.deleteUrlValue, "DELETE")
  }

  async mutateProvisionItem(event, template, method) {
    try {
      const url = template
        .replace("__TYPE__", encodeURIComponent(event.params.type))
        .replace("__NAME__", encodeURIComponent(event.params.name))
      const data = await this.request(url, { method })
      this.renderProvision(data)
    } catch (error) {
      this.showError(error.message)
    }
  }

  renderEngines(engines) {
    const table = document.createElement("table")
    table.className = "settings-table"
    table.style.width = "100%"
    const body = document.createElement("tbody")

    engines.forEach((engine) => {
      const row = document.createElement("tr")
      const name = document.createElement("td")
      const strong = document.createElement("strong")
      strong.textContent = engine.engine
      name.append(strong)
      const state = document.createElement("td")
      state.textContent = this.statusLabel(engine.status?.state || "unknown")
      if (engine.status?.detail) {
        const detail = document.createElement("div")
        detail.className = "text-muted"
        detail.textContent = engine.status.detail
        state.append(detail)
      }
      const action = document.createElement("td")
      const flows = engine.flows?.length ? engine.flows : [engine.flow].filter(Boolean)
      flows.forEach((flow) => {
        const button = document.createElement("button")
        button.type = "button"
        button.className = "btn btn-sm btn-primary mr-1"
        button.textContent = `${this.loginValue} (${flow})`
        button.dataset.engine = engine.engine
        button.dataset.flow = flow
        button.dataset.action = "agent-connection#login"
        action.append(button)
      })
      row.append(name, state, action)
      body.append(row)
    })

    table.append(body)
    this.enginesTarget.replaceChildren(table)
  }

  renderProvision(data) {
    this.renderManifestState(data)
    const items = data.items || data.data || []
    const expected = [
      { type: "skill", name: "collavre" },
      { type: "config", name: "collavre" }
    ]
    this.provisionTarget.replaceChildren(...expected.map((expectedItem) => {
      const item = items.find((candidate) => candidate.type === expectedItem.type && candidate.name === expectedItem.name) || expectedItem
      const row = document.createElement("tr")
      const itemStatus = item.status || item.state || "not_synced"
      ;[item.name, item.type, itemStatus].forEach((value, index) => {
        const cell = document.createElement("td")
        if (index === 0) {
          const strong = document.createElement("strong")
          strong.textContent = value
          cell.append(strong)
        } else {
          cell.textContent = index === 2 ? this.statusLabel(value) : this.itemTypeLabel(value)
        }
        row.append(cell)
      })
      const actions = document.createElement("td")
      if (itemStatus === "pending_approval") {
        actions.append(this.provisionButton(this.approveValue, "approveItem", item))
      } else if (["installed", "failed"].includes(itemStatus)) {
        actions.append(this.provisionButton(this.revokeValue, "revokeItem", item))
      }
      row.append(actions)
      return row
    }))
  }

  // Why provisioning is not happening, which the per-item states cannot say:
  // an unregistered manifest leaves every item at "not synced", and a manifest
  // the proxy could not fetch or parse leaves them at their previous state.
  // Both are repaired by "Sync now", so name the cause next to that button.
  renderManifestState(data) {
    if (!this.hasManifestTarget) return
    const notice = document.createElement("div")
    if (data.last_error) {
      notice.className = "alert alert-danger"
      notice.textContent = `${this.lastErrorValue}: ${data.last_error}`
    } else if (!data.manifest_url) {
      notice.className = "alert alert-warning"
      notice.textContent = this.manifestUnregisteredValue
    } else {
      this.manifestTarget.replaceChildren()
      return
    }
    this.manifestTarget.replaceChildren(notice)
  }

  provisionButton(label, action, item) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-sm btn-secondary"
    button.textContent = label
    button.dataset.action = `agent-connection#${action}`
    button.dataset.agentConnectionTypeParam = item.type
    button.dataset.agentConnectionNameParam = item.name
    return button
  }

  itemTypeLabel(type) {
    return this.itemTypeLabelsValue[type] || type
  }

}
