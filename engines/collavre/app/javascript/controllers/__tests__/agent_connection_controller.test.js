/**
 * @jest-environment jsdom
 */
import { Application } from "@hotwired/stimulus"
import { jest } from "@jest/globals"

const { default: AgentConnectionController } = await import("../agent_connection_controller")

describe("AgentConnectionController", () => {
  let application

  async function mount() {
    document.body.innerHTML = `
      <div data-controller="agent-connection"
           data-agent-connection-status-url-value="/status"
           data-agent-connection-session-url-value="/auth/__ENGINE__"
           data-agent-connection-session-detail-url-value="/auth/__ENGINE__/__SESSION__"
           data-agent-connection-sync-url-value="/sync"
           data-agent-connection-approve-url-value="/items/__TYPE__/__NAME__/approve"
           data-agent-connection-delete-url-value="/items/__TYPE__/__NAME__"
           data-agent-connection-login-value="로그인"
           data-agent-connection-submit-value="제출"
           data-agent-connection-base-url-label-value="Provider base URL"
           data-agent-connection-base-url-help-value="공개 HTTPS 주소를 입력하세요"
           data-agent-connection-cancel-value="취소"
           data-agent-connection-open-url-value="인증 페이지 열기"
           data-agent-connection-approve-value="승인"
           data-agent-connection-revoke-value="승인 회수"
           data-agent-connection-error-value="CLI Proxy 오류"
           data-agent-connection-manifest-unregistered-value="등록된 매니페스트가 없습니다"
           data-agent-connection-last-error-value="최근 프로비저닝 오류"
           data-agent-connection-status-labels-value='{"unknown":"알 수 없음","authorized":"인증 완료","not_synced":"동기화되지 않음","pending_approval":"승인 대기","installed":"설치됨"}'
           data-agent-connection-item-type-labels-value='{"skill":"스킬","config":"설정"}'>
        <div data-agent-connection-target="error" hidden></div>
        <div data-agent-connection-target="engines"></div>
        <div data-agent-connection-target="session"></div>
        <div data-agent-connection-target="manifest"></div>
        <table><tbody data-agent-connection-target="provision"></tbody></table>
      </div>
    `

    application = Application.start()
    application.register("agent-connection", AgentConnectionController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  beforeEach(() => {
    global.fetch = async () => ({
      ok: true,
      text: async () => JSON.stringify({
        engines: [{ engine: "claude", status: { state: "unknown" }, flows: [] }],
        provision: { items: [{ type: "skill", name: "collavre", status: "installed" }] }
      })
    })
  })

  afterEach(() => {
    jest.useRealTimers()
    application?.stop()
    application = null
    document.body.innerHTML = ""
    delete global.fetch
  })

  test("renders engine, provisioning, and session states with localized labels", async () => {
    await mount()

    expect(document.querySelector('[data-agent-connection-target="engines"]').textContent).toContain("알 수 없음")
    expect(document.querySelector('[data-agent-connection-target="provision"]').textContent).toContain("설치됨")
    expect(document.querySelector('[data-agent-connection-target="provision"]').textContent).toContain("동기화되지 않음")
    expect(document.querySelector('[data-agent-connection-target="provision"]').textContent).toContain("스킬")
    expect(document.querySelector('[data-agent-connection-target="provision"]').textContent).toContain("설정")
    expect(document.querySelector('[data-agent-connection-target="provision"]').textContent).not.toMatch(/skill|config/)

    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )
    controller.renderSession({ engine: "claude", status: "authorized", sessionId: "session-1" })

    expect(document.querySelector('[data-agent-connection-target="session"]').textContent).toContain("claude: 인증 완료")
  })

  test("falls back to a new proxy status identifier until a translation is added", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )

    expect(controller.statusLabel("future_state")).toBe("future_state")
    expect(controller.itemTypeLabel("future_type")).toBe("future_type")
  })

  test("names why provisioning is stalled next to the sync button", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )
    const manifest = document.querySelector('[data-agent-connection-target="manifest"]')

    expect(manifest.textContent).toContain("등록된 매니페스트가 없습니다")

    controller.renderProvision({ manifest_url: "https://collavre.example/provision.json", last_error: "manifest fetch failed" })
    expect(manifest.textContent).toContain("최근 프로비저닝 오류: manifest fetch failed")

    controller.renderProvision({ manifest_url: "https://collavre.example/provision.json", items: [] })
    expect(manifest.textContent).toBe("")
  })

  test("submits provider credentials under a log-filtered parameter name", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )
    controller.sessionTarget.innerHTML = '<input data-role="secret" value="provider-secret">'
    let submitted
    global.fetch = async (_url, options) => {
      submitted = JSON.parse(options.body)
      return { ok: true, text: async () => JSON.stringify({ engine: "codex", status: "pending" }) }
    }

    await controller.submit({ params: { engine: "codex", session: "session-1" } })

    expect(submitted).toEqual({ auth_secret: "provider-secret" })
  })

  test("renders and submits base URL only for an advertised custom-provider flow", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )
    controller.baseUrlFlows = new Map([["codex_custom", ["api-key"]]])
    controller.renderSession({ engine: "codex_custom", flow: "api-key", status: "pending", sessionId: "session-1" })

    const baseUrl = document.querySelector('[data-role="base-url"]')
    const secret = document.querySelector('[data-role="secret"]')
    expect(baseUrl).not.toBeNull()
    expect(secret).not.toBeNull()
    expect(document.querySelector('[data-agent-connection-target="session"]').textContent).toContain("Provider base URL")
    baseUrl.value = "https://openrouter.ai/api/v1"
    secret.value = "provider-secret"

    let submitted
    global.fetch = async (_url, options) => {
      submitted = JSON.parse(options.body)
      return { ok: true, text: async () => JSON.stringify({ engine: "codex_custom", status: "pending" }) }
    }
    await controller.submit({ params: { engine: "codex_custom", session: "session-1" } })

    expect(submitted).toEqual({ auth_secret: "provider-secret", base_url: "https://openrouter.ai/api/v1" })

    controller.baseUrlFlows = new Map()
    controller.renderSession({ engine: "codex", flow: "api-key", status: "pending", sessionId: "session-2" })
    expect(document.querySelector('[data-role="base-url"]')).toBeNull()
  })

  test("does not submit a custom-provider session without a valid base URL", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )
    controller.baseUrlFlows = new Map([["codex_custom", ["api-key"]]])
    controller.renderSession({ engine: "codex_custom", flow: "api-key", status: "pending", sessionId: "session-1" })

    const baseUrl = document.querySelector('[data-role="base-url"]')
    let reportValidityCalls = 0
    let fetchCalled = false
    baseUrl.reportValidity = () => {
      reportValidityCalls += 1
      return false
    }
    global.fetch = async () => { fetchCalled = true }

    await controller.submit({ params: { engine: "codex_custom", session: "session-1" } })

    expect(reportValidityCalls).toBe(1)
    expect(fetchCalled).toBe(false)
  })

  test("shows routing detail and remains compatible with proxies without base URL flows", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )

    controller.renderEngines([{ engine: "codex_custom", flow: "api-key", status: { state: "authenticated", detail: "routing to https://openrouter.ai/api/v1" } }])

    expect(document.querySelector('[data-agent-connection-target="engines"]').textContent).toContain("routing to https://openrouter.ai/api/v1")
    expect(controller.requiresBaseUrl("codex_custom", "api-key")).toBe(false)
  })
  test("inline paste-code submits the secret directly and retries only after authorization", async () => {
    await mount()
    const element = document.querySelector('[data-controller="agent-connection"]')
    const controller = application.getControllerForElementAndIdentifier(element, "agent-connection")
    controller.resumeUrlValue = "/resume"
    controller.resumedValue = "Request queued again"
    const calls = []
    global.fetch = async (url, options = {}) => {
      calls.push({ url, body: options.body && JSON.parse(options.body) })
      return { ok: true, text: async () => JSON.stringify(url === "/resume" ? { resumed: true } : {
        engine: "claude", sessionId: "one", flow: "paste-code",
        status: url === "/auth/claude" ? "pending" : "authorized",
        verificationUrl: "https://claude.com/login"
      }) }
    }
    await controller.login({ currentTarget: { dataset: { engine: "claude", flow: "paste-code" } } })
    const secret = element.querySelector('[data-role="secret"]')
    expect(secret.type).toBe("password")
    secret.value = "private-code"
    await controller.submit({ params: { engine: "claude", session: "one" } })
    expect(calls.map(call => call.url)).toEqual(["/auth/claude", "/auth/claude/one", "/resume"])
    expect(calls[1].body).toEqual({ auth_secret: "private-code" })
    expect(secret.value).toBe("")
    expect(element.textContent).toContain("Request queued again")
    expect(element.textContent).not.toContain("private-code")
  })

  test("device login renders the user code and polls without posting a secret", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(document.querySelector('[data-controller="agent-connection"]'), "agent-connection")
    let polled
    controller.poll = async (...args) => { polled = args }
    global.fetch = async () => ({ ok: true, text: async () => JSON.stringify({
      engine: "codex", flow: "device-code", status: "pending", sessionId: "device",
      userCode: "ABCD-EFGH", verificationUrl: "https://auth.openai.com/codex/device", expiresAt: "2099-01-01T00:00:00Z"
    }) })
    await controller.login({ currentTarget: { dataset: { engine: "codex", flow: "device-code" } } })
    expect(document.body.textContent).toContain("ABCD-EFGH")
    expect(document.querySelector('[data-role="secret"]')).toBeNull()
    expect(polled.slice(0, 3)).toEqual(["codex", "device", "2099-01-01T00:00:00Z"])
  })

  test("expired or superseded polls cannot resume a turn and unsafe login URLs are not linked", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(document.querySelector('[data-controller="agent-connection"]'), "agent-connection")
    controller.sessionGeneration = 2
    controller.expiredValue = "Login expired"
    let requests = 0
    global.fetch = async () => { requests++; throw new Error("must not fetch") }
    await controller.poll("codex", "old", "2099-01-01T00:00:00Z", 1)
    await controller.poll("codex", "expired", "2000-01-01T00:00:00Z", 2)
    expect(requests).toBe(0)
    expect(document.body.textContent).toContain("Login expired")
    controller.renderSession({ engine: "claude", status: "pending", flow: "paste-code", verificationUrl: "javascript:alert(1)" })
    expect(controller.sessionTarget.querySelector("a")).toBeNull()
  })

  test("login errors remain visible and a disconnected pending start cannot render its response", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(document.querySelector('[data-controller="agent-connection"]'), "agent-connection")
    global.fetch = async () => ({ ok: false, text: async () => JSON.stringify({ error: { code: "session_superseded", message: "Start again" } }) })
    await controller.login({ currentTarget: { dataset: { engine: "codex", flow: "device-code" } } })
    expect(controller.errorTarget.textContent).toContain("Start again")
    let finish
    global.fetch = () => new Promise(resolve => { finish = resolve })
    const pending = controller.login({ currentTarget: { dataset: { engine: "claude", flow: "paste-code" } } })
    controller.disconnect()
    finish({ ok: true, text: async () => JSON.stringify({ status: "pending", engine: "claude", sessionId: "late" }) })
    await pending
    expect(controller.sessionTarget.childElementCount).toBe(0)
  })

  describe("authentication session recovery", () => {
    let controller
    const session = {
      engine: "codex", flow: "device-code", status: "pending", sessionId: "device",
      expiresAt: "2099-01-01T00:00:00Z"
    }
    const event = { params: { engine: "codex", session: "device" } }
    const response = (data, ok = true) => ({ ok, text: async () => JSON.stringify(data) })

    beforeEach(async () => {
      await mount()
      controller = application.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller="agent-connection"]'), "agent-connection"
      )
      controller.sessionGeneration = 1
      controller.resumeUrlValue = "/resume"
      controller.resumedValue = "Request queued again"
      jest.useFakeTimers()
    })

    test("polls a pending device session until authorized, then resumes exactly once", async () => {
      global.fetch = jest.fn()
        .mockResolvedValueOnce(response(session))
        .mockResolvedValueOnce(response({ ...session, status: "authorized" }))
        .mockResolvedValueOnce(response({ resumed: true }))

      const polling = controller.poll("codex", "device", session.expiresAt, 1)
      await jest.advanceTimersByTimeAsync(3000)
      expect(global.fetch).toHaveBeenCalledTimes(1)
      expect(controller.sessionTarget.textContent).toContain("pending")
      await jest.advanceTimersByTimeAsync(3000)
      await polling

      expect(global.fetch.mock.calls.map(([url]) => url)).toEqual([
        "/auth/codex/device", "/auth/codex/device", "/resume"
      ])
      expect(global.fetch.mock.calls[2][1].method).toBe("POST")
      expect(controller.sessionTarget.textContent).toBe("Request queued again")
      expect(controller.enginesTarget.childElementCount).toBe(0)
      expect(jest.getTimerCount()).toBe(0)
    })

    test("reconnecting a pending device session continues polling without starting a new login", async () => {
      controller.renderSession(session)
      controller.disconnect()
      global.fetch = jest.fn()
        .mockResolvedValueOnce(response({ ...session, status: "authorized" }))
        .mockResolvedValueOnce(response({ resumed: true }))

      controller.connect()
      await jest.advanceTimersByTimeAsync(3000)

      expect(global.fetch.mock.calls.map(([url]) => url)).toEqual(["/auth/codex/device", "/resume"])
      expect(controller.sessionTarget.textContent).toBe("Request queued again")
    })

    test("failed device authorization shows the reason and refreshes status without resuming", async () => {
      global.fetch = jest.fn()
        .mockResolvedValueOnce(response({ ...session, status: "failed", error: { message: "Access denied" } }))
        .mockResolvedValueOnce(response({ engines: [] }))

      const polling = controller.poll("codex", "device", session.expiresAt, 1)
      await jest.advanceTimersByTimeAsync(3000)
      await polling

      expect(controller.sessionTarget.textContent).toContain("Access denied")
      expect(global.fetch.mock.calls.map(([url]) => url)).toEqual(["/auth/codex/device", "/status"])
      expect(jest.getTimerCount()).toBe(0)
    })

    test("poll transport errors stay visible without resuming or continuing to poll", async () => {
      global.fetch = jest.fn().mockRejectedValue(new Error("Session superseded"))
      const polling = controller.poll("codex", "device", session.expiresAt, 1)
      await jest.advanceTimersByTimeAsync(3000)
      await polling

      expect(controller.errorTarget.hidden).toBe(false)
      expect(controller.errorTarget.textContent).toContain("Session superseded")
      expect(global.fetch).toHaveBeenCalledTimes(1)
      expect(jest.getTimerCount()).toBe(0)
    })

    test("disconnecting during a poll delay prevents the HTTP request", async () => {
      global.fetch = jest.fn()
      const polling = controller.poll("codex", "device", session.expiresAt, 1)
      controller.disconnect()
      await jest.advanceTimersByTimeAsync(3000)
      await polling

      expect(global.fetch).not.toHaveBeenCalled()
    })

    test.each(["authorized", "error"])("a late %s poll response cannot overwrite a replacement session", async (outcome) => {
      let finish, fail
      global.fetch = jest.fn(() => new Promise((resolve, reject) => { finish = resolve; fail = reject }))
      const polling = controller.poll("codex", "device", session.expiresAt, 1)
      await jest.advanceTimersByTimeAsync(3000)
      controller.sessionGeneration++
      controller.renderSession({ ...session, sessionId: "replacement", flow: "api-key" })
      const form = controller.sessionTarget.firstElementChild
      if (outcome === "error") fail(new Error("Old session failed"))
      else finish(response({ ...session, status: "authorized" }))
      await polling

      expect(controller.sessionTarget.firstElementChild).toBe(form)
      expect(controller.liveSession.sessionId).toBe("replacement")
      expect(controller.errorTarget.hidden).toBe(true)
      expect(global.fetch).toHaveBeenCalledTimes(1)
    })

    test("cancelling stops pending polling, clears the session and refreshes login choices", async () => {
      controller.renderSession(session)
      global.fetch = jest.fn()
        .mockResolvedValueOnce({ ok: true, text: async () => "" })
        .mockResolvedValueOnce(response({ engines: [] }))
      const polling = controller.poll("codex", "device", session.expiresAt, 1)

      await controller.cancel(event)
      await jest.advanceTimersByTimeAsync(3000)
      await polling

      expect(global.fetch.mock.calls.map(([url]) => url)).toEqual(["/auth/codex/device", "/status"])
      expect(global.fetch.mock.calls[0][1].method).toBe("DELETE")
      expect(controller.liveSession).toBeNull()
      expect(controller.sessionTarget.childElementCount).toBe(0)
    })

    test("a failed cancellation keeps the session available for retry and displays a fallback error", async () => {
      controller.renderSession(session)
      global.fetch = jest.fn().mockResolvedValue(response({}, false))

      await controller.cancel(event)

      expect(controller.liveSession).toEqual(session)
      expect(controller.sessionTarget.childElementCount).toBe(1)
      expect(controller.errorTarget.hidden).toBe(false)
      expect(controller.errorTarget.textContent).toContain("CLI Proxy 오류")
      expect(global.fetch).toHaveBeenCalledTimes(1)
    })

    test("rejected code submissions display an error and clear the password input", async () => {
      controller.renderSession({ ...session, flow: "api-key" })
      const secret = controller.sessionTarget.querySelector('[data-role="secret"]')
      secret.value = "private-key"
      global.fetch = jest.fn().mockRejectedValue(new Error("Submission rejected"))

      await controller.submit(event)

      expect(secret.value).toBe("")
      expect(controller.errorTarget.textContent).toContain("Submission rejected")
      expect(controller.errorTarget.hidden).toBe(false)
      expect(global.fetch).toHaveBeenCalledTimes(1)
    })

    test("connection settings refresh after authorization when there is no chat to resume", async () => {
      controller.element.removeAttribute("data-agent-connection-resume-url-value")
      global.fetch = jest.fn()
        .mockResolvedValueOnce(response({ ...session, status: "authorized" }))
        .mockResolvedValueOnce(response({ engines: [{ engine: "codex", status: { state: "authenticated" } }] }))

      await controller.login({ currentTarget: { dataset: { engine: "codex", flow: "api-key" } } })
      await jest.advanceTimersByTimeAsync(0)

      expect(global.fetch.mock.calls.map(([url]) => url)).toEqual(["/auth/codex", "/status"])
      expect(controller.enginesTarget.textContent).toContain("authenticated")
    })

    test.each(["authorized", "error"])("a late %s submission clears its secret without affecting the new login", async (outcome) => {
      controller.renderSession({ ...session, flow: "api-key" })
      const secret = controller.sessionTarget.querySelector('[data-role="secret"]')
      secret.value = "private-key"
      let finish, fail
      global.fetch = jest.fn(() => new Promise((resolve, reject) => { finish = resolve; fail = reject }))
      const submission = controller.submit(event)
      controller.sessionGeneration++
      controller.renderSession({ ...session, sessionId: "replacement", flow: "api-key" })
      const replacement = controller.sessionTarget.querySelector('[data-role="secret"]')
      replacement.value = "new-key"

      if (outcome === "error") fail(new Error("Old submission failed"))
      else finish(response({ ...session, status: "authorized" }))
      await submission

      expect(secret.value).toBe("")
      expect(replacement.value).toBe("new-key")
      expect(controller.liveSession.sessionId).toBe("replacement")
      expect(controller.errorTarget.hidden).toBe(true)
      expect(global.fetch).toHaveBeenCalledTimes(1)
    })
  })
})
