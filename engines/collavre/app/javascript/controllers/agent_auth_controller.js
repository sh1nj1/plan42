import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { resumeUrl: String, resumed: String, expired: String }

  connect() {
    this.disconnected = false
    if (this.liveSession?.status === "pending") {
      this.resumePolling(this.liveSession, this.sessionGeneration)
    } else {
      this.refresh()
    }
  }

  disconnect() {
    this.disconnected = true
    this.sessionGeneration = (this.sessionGeneration || 0) + 1
  }

  async login(event) {
    this.hideError()
    const generation = this.sessionGeneration = (this.sessionGeneration || 0) + 1
    const engine = event.currentTarget.dataset.engine
    const flow = event.currentTarget.dataset.flow
    try {
      const data = await this.request(this.sessionUrl(engine), {
        method: "POST",
        body: JSON.stringify({ flow })
      })
      if (this.disconnected || generation !== this.sessionGeneration) return
      this.restoreSession(data, generation)
      if (data.status === "authorized") await this.authorized()
    } catch (error) {
      this.showError(error.message)
    }
  }

  async submit(event) {
    const secret = this.sessionTarget.querySelector('[data-role="secret"]')
    const baseUrl = this.sessionTarget.querySelector('[data-role="base-url"]')
    if (baseUrl && !baseUrl.checkValidity()) {
      baseUrl.reportValidity()
      return
    }

    const generation = this.sessionGeneration
    try {
      const data = await this.request(this.sessionDetailUrl(event.params.engine, event.params.session), {
        method: "POST",
        body: JSON.stringify({
          auth_secret: secret?.value || "",
          ...(baseUrl ? { base_url: baseUrl.value } : {})
        })
      })
      if (!this.currentSession(generation)) return
      this.renderSession(data)
      if (data.status === "authorized") await this.authorized()
    } catch (error) {
      if (this.currentSession(generation)) this.showError(error.message)
    } finally {
      if (secret) secret.value = ""
    }
  }

  async cancel(event) {
    try {
      await this.request(this.sessionDetailUrl(event.params.engine, event.params.session), { method: "DELETE" })
      this.sessionGeneration = (this.sessionGeneration || 0) + 1
      this.liveSession = null
      this.sessionTarget.replaceChildren()
      this.refresh()
    } catch (error) {
      this.showError(error.message)
    }
  }

  restoreSession(session, generation = this.sessionGeneration = (this.sessionGeneration || 0) + 1) {
    this.renderSession(session)
    this.resumePolling(session, generation)
  }

  resumePolling(session, generation) {
    if (session.status === "pending" && session.flow === "device-code") {
      this.poll(session.engine, session.sessionId, session.expiresAt, generation)
    }
  }

  renderSession(session) {
    this.liveSession = session
    const panel = document.createElement("div")
    panel.className = "alert alert-info mt-2"
    const title = document.createElement("strong")
    title.textContent = `${session.engine}: ${this.statusLabel(session.status)}`
    panel.append(title)

    if (this.safeVerificationUrl(session.verificationUrl) && session.status === "pending") {
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
      this.appendSecretForm(panel, session)
    }
    if (session.status === "pending") panel.append(this.actionButton(this.cancelValue, "agent-connection#cancel", session))
    if (session.error?.message) {
      const error = document.createElement("p")
      error.textContent = session.error.message
      panel.append(error)
    }
    this.sessionTarget.replaceChildren(panel)
  }

  appendSecretForm(panel, session) {
    if (this.requiresBaseUrl(session.engine, session.flow)) {
      const baseUrlLabel = document.createElement("label")
      baseUrlLabel.className = "mt-2"
      baseUrlLabel.textContent = this.baseUrlLabelValue
      const baseUrlHelp = document.createElement("p")
      baseUrlHelp.className = "text-muted"
      baseUrlHelp.textContent = this.baseUrlHelpValue
      const baseUrl = document.createElement("input")
      baseUrl.type = "url"
      baseUrl.className = "stacked-form-control"
      baseUrl.placeholder = "https://openrouter.ai/api/v1"
      baseUrl.dataset.role = "base-url"
      baseUrl.required = true
      panel.append(baseUrlLabel, baseUrlHelp, baseUrl)
    }
    const secret = document.createElement("input")
    secret.type = "password"
    secret.autocomplete = "off"
    secret.setAttribute("aria-label", this.submitValue)
    secret.className = "stacked-form-control mt-2"
    secret.dataset.role = "secret"
    const submit = this.actionButton(this.submitValue, "agent-connection#submit", session)
    panel.append(secret, submit)

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

  requiresBaseUrl(engine, flow) {
    return (this.baseUrlFlows?.get(engine) || []).includes(flow)
  }

  async poll(engine, sessionId, expiresAt, generation) {
    if (!this.currentSession(generation)) return
    if (!Number.isFinite(Date.parse(expiresAt)) || Date.now() >= Date.parse(expiresAt)) {
      this.liveSession = null
      this.sessionTarget.replaceChildren()
      this.showError(this.expiredValue || this.errorValue)
      return
    }
    await new Promise((resolve) => window.setTimeout(resolve, 3000))
    if (!this.currentSession(generation)) return
    try {
      const session = await this.request(this.sessionDetailUrl(engine, sessionId))
      if (!this.currentSession(generation)) return
      this.renderSession(session)
      if (session.status === "pending") return this.poll(engine, sessionId, expiresAt, generation)
      if (session.status === "authorized") await this.authorized()
      else this.refresh()
    } catch (error) {
      if (this.currentSession(generation)) this.showError(error.message)
    }
  }

  currentSession(generation) {
    return !this.disconnected && generation === this.sessionGeneration
  }

  safeVerificationUrl(value) {
    try { return new URL(value).protocol === "https:" } catch { return false }
  }

  async authorized() {
    if (this.hasResumeUrlValue) {
      await this.request(this.resumeUrlValue, { method: "POST" })
      this.sessionTarget.replaceChildren(document.createTextNode(this.resumedValue))
      this.enginesTarget.replaceChildren()
    } else {
      this.refresh()
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
