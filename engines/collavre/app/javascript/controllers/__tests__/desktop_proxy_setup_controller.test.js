/**
 * @jest-environment jsdom
 */

import { jest } from "@jest/globals"

const csrfFetch = jest.fn()
jest.unstable_mockModule("../../lib/api/csrf_fetch", () => ({ default: csrfFetch }))

const { Application } = await import("@hotwired/stimulus")
const { default: DesktopProxySetupController, setupNextUrl } = await import("../desktop_proxy_setup_controller")

describe("DesktopProxySetupController", () => {
  let application
  let controller

  beforeEach(async () => {
    csrfFetch.mockReset()
    document.body.innerHTML = `
      <div data-controller="desktop-proxy-setup"
           data-desktop-proxy-setup-token-url-value="/desktop/setup/registration_token"
           data-desktop-proxy-setup-next-url-value="/desktop/setup?step=adapters"
           data-desktop-proxy-setup-unavailable-value="Desktop support is unavailable"
           data-desktop-proxy-setup-failed-value="Setup failed">
        <input type="checkbox" data-desktop-proxy-setup-target="consent">
      <button disabled data-desktop-proxy-setup-target="submit"></button>
        <p hidden data-desktop-proxy-setup-target="error"></p>
      </div>`
    application = Application.start()
    application.register("desktop-proxy-setup", DesktopProxySetupController)
    await new Promise((resolve) => setTimeout(resolve, 0))
    controller = application.getControllerForElementAndIdentifier(
      document.querySelector("[data-controller='desktop-proxy-setup']"),
      "desktop-proxy-setup",
    )
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ""
    delete window.__TAURI__
    jest.restoreAllMocks()
  })

  test("preserves the setup step while appending detected adapters", () => {
    expect(setupNextUrl("/desktop/setup?step=adapters", [ "claude", "codex" ]))
      .toBe("/desktop/setup?step=adapters&claude=1&codex=1")
  })

  test("enables installation only after consent", () => {
    expect(controller.submitTarget.disabled).toBe(true)

    controller.consentTarget.checked = false
    controller.toggle()
    expect(controller.submitTarget.disabled).toBe(true)

    controller.consentTarget.checked = true
    controller.toggle()
    expect(controller.submitTarget.disabled).toBe(false)
  })

  test("does not start installation without consent", async () => {
    const invoke = jest.fn()
    window.__TAURI__ = { core: { invoke } }

    await controller.install()

    expect(csrfFetch).not.toHaveBeenCalled()
    expect(invoke).not.toHaveBeenCalled()
    expect(controller.submitTarget.disabled).toBe(true)
  })

  test("registers through Tauri and retains the adapter step", async () => {
    const invoke = jest.fn().mockResolvedValue({ adapters: [ "claude" ] })
    window.__TAURI__ = { core: { invoke } }
    controller.consentTarget.checked = true
    csrfFetch.mockResolvedValue({ ok: true, json: async () => ({ token: "grant" }) })
    const navigate = jest.spyOn(controller, "navigate").mockImplementation(() => {})

    await controller.install()

    expect(csrfFetch).toHaveBeenCalledWith("/desktop/setup/registration_token", { method: "POST" })
    expect(invoke).toHaveBeenCalledWith("desktop_proxy_complete_setup", { registrationToken: "grant" })
    expect(navigate).toHaveBeenCalledWith("/desktop/setup?step=adapters&claude=1")
  })

  test("shows a localized failure when native setup is unavailable", async () => {
    controller.consentTarget.checked = true

    await controller.install()

    expect(controller.errorTarget.hidden).toBe(false)
    expect(controller.errorTarget.textContent).toBe("Desktop support is unavailable")
    expect(controller.submitTarget.disabled).toBe(false)
  })
})
