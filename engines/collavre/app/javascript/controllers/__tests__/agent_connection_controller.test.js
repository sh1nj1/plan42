/**
 * @jest-environment jsdom
 */
import { Application } from "@hotwired/stimulus"

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
})
