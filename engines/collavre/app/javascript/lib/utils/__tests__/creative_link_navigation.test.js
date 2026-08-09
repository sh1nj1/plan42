/**
 * @jest-environment jsdom
 */
import { jest } from "@jest/globals"
import { handleCreativeLinkClick } from "../creative_link_navigation"

const WORKSPACE_FRAME_ID = "creative-workspace-content"

function click(selector, options = {}) {
  const event = new MouseEvent("click", { bubbles: true, cancelable: true, ...options })
  document.querySelector(selector).dispatchEvent(event)
  return event
}

describe("creative link navigation", () => {
  let visit

  beforeEach(() => {
    document.body.innerHTML = `
      <turbo-frame id="${WORKSPACE_FRAME_ID}"></turbo-frame>
      <a id="creative-link" href="/creatives/42?open_comments=true"><span>Creative</span></a>
    `
    visit = jest.fn()
    window.Turbo = { visit }
  })

  afterEach(() => {
    delete window.Turbo
    document.body.innerHTML = ""
  })

  test("navigates a nested creative link through the workspace frame", () => {
    const event = click("#creative-link span")

    expect(event.defaultPrevented).toBe(true)
    expect(visit).toHaveBeenCalledWith("/creatives/42?open_comments=true", {
      action: "advance",
      frame: WORKSPACE_FRAME_ID,
    })
  })

  test("returns whether it handled the event", () => {
    const anchor = document.getElementById("creative-link")
    const event = new MouseEvent("click", { bubbles: true, cancelable: true })

    expect(handleCreativeLinkClick(event)).toBe(false)

    anchor.dispatchEvent(event)
    expect(event.defaultPrevented).toBe(true)
  })

  test.each([
    ["a non-creative path", { href: "/users/42" }, {}],
    ["an external URL", { href: "https://example.com/creatives/42" }, {}],
    ["a download", { download: "creative.txt" }, {}],
    ["a new-window target", { target: "_blank" }, {}],
    ["a different Turbo frame", { turboFrame: "other-frame" }, {}],
    ["a Turbo opt-out", { turboDisabled: true }, {}],
    ["a modified click", {}, { metaKey: true }],
    ["a non-primary click", {}, { button: 1 }],
  ])("keeps default navigation for %s", (_label, attributes, eventOptions) => {
    const anchor = document.getElementById("creative-link")
    if (attributes.href) anchor.setAttribute("href", attributes.href)
    if (attributes.download) anchor.setAttribute("download", attributes.download)
    if (attributes.target) anchor.setAttribute("target", attributes.target)
    if (attributes.turboFrame) anchor.dataset.turboFrame = attributes.turboFrame
    if (attributes.turboDisabled) anchor.dataset.turbo = "false"

    const event = click("#creative-link", eventOptions)

    expect(event.defaultPrevented).toBe(false)
    expect(visit).not.toHaveBeenCalled()
  })

  test("keeps default navigation without a workspace frame", () => {
    document.getElementById(WORKSPACE_FRAME_ID).remove()

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(false)
    expect(visit).not.toHaveBeenCalled()
  })

  test("keeps default navigation when Turbo is unavailable", () => {
    delete window.Turbo

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(false)
    expect(visit).not.toHaveBeenCalled()
  })

  test("respects an event already handled by another listener", () => {
    const anchor = document.getElementById("creative-link")
    anchor.addEventListener("click", (event) => event.preventDefault())

    click("#creative-link")

    expect(visit).not.toHaveBeenCalled()
  })

  test("allows an explicit self target and workspace frame", () => {
    const anchor = document.getElementById("creative-link")
    anchor.target = "_self"
    anchor.dataset.turboFrame = WORKSPACE_FRAME_ID

    click("#creative-link")

    expect(visit).toHaveBeenCalledTimes(1)
  })
})
