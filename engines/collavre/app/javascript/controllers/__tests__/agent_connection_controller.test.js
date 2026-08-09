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
           data-agent-connection-cancel-value="취소"
           data-agent-connection-open-url-value="인증 페이지 열기"
           data-agent-connection-approve-value="승인"
           data-agent-connection-revoke-value="승인 회수"
           data-agent-connection-error-value="CLI Proxy 오류"
           data-agent-connection-status-labels-value='{"unknown":"알 수 없음","authorized":"인증 완료","not_synced":"동기화되지 않음","pending_approval":"승인 대기","installed":"설치됨"}'
           data-agent-connection-item-type-labels-value='{"skill":"스킬","config":"설정"}'>
        <div data-agent-connection-target="error" hidden></div>
        <div data-agent-connection-target="engines"></div>
        <div data-agent-connection-target="session"></div>
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

  test("submits provider credentials under a log-filtered parameter name", async () => {
    await mount()
    const controller = application.getControllerForElementAndIdentifier(
      document.querySelector('[data-controller="agent-connection"]'),
      "agent-connection"
    )
    controller.sessionTarget.innerHTML = '<input value="provider-secret">'
    let submitted
    global.fetch = async (_url, options) => {
      submitted = JSON.parse(options.body)
      return { ok: true, text: async () => JSON.stringify({ engine: "codex", status: "pending" }) }
    }

    await controller.submit({ params: { engine: "codex", session: "session-1" } })

    expect(submitted).toEqual({ auth_secret: "provider-secret" })
  })
})
