import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
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

  connect() {
    this.disconnected = false
    this.refresh()
  }

  disconnect() {
    this.disconnected = true
  }

  async refresh() {
    this.hideError()
    try {
      const data = await this.request(this.statusUrlValue)
      this.renderEngines(data.engines || [])
      this.renderProvision(data.provision || {})
    } catch (error) {
      this.showError(error.message)
    }
  }

  async login(event) {
    const engine = event.currentTarget.dataset.engine
    const flow = event.currentTarget.dataset.flow
    try {
      const data = await this.request(this.sessionUrl(engine), {
        method: "POST",
        body: JSON.stringify({ flow })
      })
      this.renderSession(data)
      if (data.flow === "device-code") this.poll(engine, data.sessionId, data.expiresAt)
    } catch (error) {
      this.showError(error.message)
    }
  }

  async submit(event) {
    const input = this.sessionTarget.querySelector("input")
    try {
      const data = await this.request(this.sessionDetailUrl(event.params.engine, event.params.session), {
        method: "POST",
        body: JSON.stringify({ auth_secret: input?.value || "" })
      })
      this.renderSession(data)
      if (data.status === "authorized") this.refresh()
    } catch (error) {
      this.showError(error.message)
    }
  }

  async cancel(event) {
    try {
      await this.request(this.sessionDetailUrl(event.params.engine, event.params.session), { method: "DELETE" })
      this.sessionTarget.replaceChildren()
      this.refresh()
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

  renderSession(session) {
    const panel = document.createElement("div")
    panel.className = "alert alert-info mt-2"
    const title = document.createElement("strong")
    title.textContent = `${session.engine}: ${this.statusLabel(session.status)}`
    panel.append(title)

    if (session.verificationUrl) {
      const link = document.createElement("a")
      link.href = session.verificationUrl
      link.target = "_blank"
      link.rel = "noopener"
      link.textContent = this.openUrlValue
      link.className = "btn btn-sm btn-secondary ml-2"
      panel.append(link)
    }
    if (session.userCode) {
      const code = document.createElement("p")
      code.className = "provision-user-code"
      code.textContent = session.userCode
      panel.append(code)
    }

    if (session.status === "pending" && session.flow !== "device-code") {
      const input = document.createElement("input")
      input.type = session.flow === "api-key" ? "password" : "text"
      input.className = "stacked-form-control mt-2"
      const submit = this.actionButton(this.submitValue, "agent-connection#submit", session)
      panel.append(input, submit)
    }
    if (session.status === "pending") panel.append(this.actionButton(this.cancelValue, "agent-connection#cancel", session))
    if (session.error?.message) {
      const error = document.createElement("p")
      error.textContent = session.error.message
      panel.append(error)
    }
    this.sessionTarget.replaceChildren(panel)
  }

  actionButton(label, action, session) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "btn btn-sm btn-secondary mt-2"
    button.textContent = label
    button.dataset.action = action
    button.dataset.agentConnectionEngineParam = session.engine
    button.dataset.agentConnectionSessionParam = session.sessionId
    return button
  }

  statusLabel(status) {
    return this.statusLabelsValue[status] || status
  }

  itemTypeLabel(type) {
    return this.itemTypeLabelsValue[type] || type
  }

  async poll(engine, sessionId, expiresAt) {
    if (this.disconnected || Date.now() >= Date.parse(expiresAt)) return
    await new Promise((resolve) => window.setTimeout(resolve, 3000))
    if (this.disconnected) return
    try {
      const session = await this.request(this.sessionDetailUrl(engine, sessionId))
      this.renderSession(session)
      if (session.status === "pending") return this.poll(engine, sessionId, expiresAt)
      this.refresh()
    } catch (error) {
      this.showError(error.message)
    }
  }

  sessionUrl(engine) {
    return this.sessionUrlValue.replace("__ENGINE__", encodeURIComponent(engine))
  }

  sessionDetailUrl(engine, session) {
    return this.sessionDetailUrlValue
      .replace("__ENGINE__", encodeURIComponent(engine))
      .replace("__SESSION__", encodeURIComponent(session))
  }

  async request(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "",
        "Content-Type": "application/json",
        Accept: "application/json",
        ...(options.headers || {})
      }
    })
    const text = await response.text()
    const data = text ? JSON.parse(text) : {}
    if (!response.ok) throw new Error(data.error?.message || this.errorValue)
    return data
  }

  showError(message) {
    this.errorTarget.textContent = `${this.errorValue}: ${message}`
    this.errorTarget.hidden = false
  }

  hideError() {
    this.errorTarget.hidden = true
  }
}
