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
      <turbo-frame id="${WORKSPACE_FRAME_ID}" data-collavre-mount-path=""></turbo-frame>
      <div id="link-container"><a id="creative-link" href="/creatives/42?open_comments=true"><span>Creative</span></a></div>
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

  test("navigates a creative link under the engine mount path", () => {
    const anchor = document.getElementById("creative-link")
    document.getElementById(WORKSPACE_FRAME_ID).dataset.collavreMountPath = "/collavre"
    anchor.setAttribute("href", "/collavre/creatives/42?open_comments=true")

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(true)
    expect(visit).toHaveBeenCalledWith("/collavre/creatives/42?open_comments=true", {
      action: "advance",
      frame: WORKSPACE_FRAME_ID,
    })
  })

  test.each([
    "/creatives?id=42",
  ])("navigates the canonical workspace link %s through the workspace frame", (href) => {
    const anchor = document.getElementById("creative-link")
    anchor.setAttribute("href", href)

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(true)
    expect(visit).toHaveBeenCalledWith(href, {
      action: "advance",
      frame: WORKSPACE_FRAME_ID,
    })
  })

  test("navigates a canonical workspace link under the engine mount path", () => {
    const href = "/collavre/creatives?open_comments=true&id=42"
    const anchor = document.getElementById("creative-link")
    document.getElementById(WORKSPACE_FRAME_ID).dataset.collavreMountPath = "/collavre"
    anchor.setAttribute("href", href)

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(true)
    expect(visit).toHaveBeenCalledWith(href, {
      action: "advance",
      frame: WORKSPACE_FRAME_ID,
    })
  })

  test.each([
    "/creatives/42/comments/456",
    `${window.location.origin}/creatives/42/comments/456`,
  ])("navigates the comment permalink %s through the workspace frame", (href) => {
    const anchor = document.getElementById("creative-link")
    anchor.setAttribute("href", href)

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(true)
    expect(visit).toHaveBeenCalledWith(href, {
      action: "advance",
      frame: WORKSPACE_FRAME_ID,
    })
  })

  test("navigates a comment permalink under the engine mount path", () => {
    const href = "/collavre/creatives/42/comments/456"
    const anchor = document.getElementById("creative-link")
    document.getElementById(WORKSPACE_FRAME_ID).dataset.collavreMountPath = "/collavre"
    anchor.setAttribute("href", href)

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(true)
    expect(visit).toHaveBeenCalledWith(href, {
      action: "advance",
      frame: WORKSPACE_FRAME_ID,
    })
  })

  test.each([
    "/admin/creatives/42",
    "/creatives/42",
  ])("keeps default navigation outside the configured engine mount for %s", (href) => {
    const anchor = document.getElementById("creative-link")
    document.getElementById(WORKSPACE_FRAME_ID).dataset.collavreMountPath = "/collavre"
    anchor.setAttribute("href", href)

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(false)
    expect(visit).not.toHaveBeenCalled()
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
    ["an invalid URL", { href: "http://[" }, {}],
    ["a creative slide view", { href: "/creatives/42/slide_view" }, {}],
    ["a nested creative route", { href: "/creatives/42/topics" }, {}],
    ["a creative index without an id", { href: "/creatives?search=target" }, {}],
    ["a creative index with an invalid id", { href: "/creatives?id=target" }, {}],
    ["a nested comment action", { href: "/creatives/42/comments/456/download_images" }, {}],
    ["a download", { download: "creative.txt" }, {}],
    ["a new-window target", { target: "_blank" }, {}],
    ["a different Turbo frame", { turboFrame: "other-frame" }, {}],
    ["a Turbo opt-out", { turboDisabled: true }, {}],
    ["a contenteditable editor", { contentEditable: true }, {}],
    ["a Lexical editor", { lexicalEditor: true }, {}],
    ["a modified click", {}, { metaKey: true }],
    ["a non-primary click", {}, { button: 1 }],
  ])("keeps default navigation for %s", (_label, attributes, eventOptions) => {
    const anchor = document.getElementById("creative-link")
    if (attributes.href) anchor.setAttribute("href", attributes.href)
    if (attributes.download) anchor.setAttribute("download", attributes.download)
    if (attributes.target) anchor.setAttribute("target", attributes.target)
    if (attributes.turboFrame) anchor.dataset.turboFrame = attributes.turboFrame
    if (attributes.turboDisabled) anchor.dataset.turbo = "false"
    if (attributes.contentEditable) anchor.parentElement.setAttribute("contenteditable", "true")
    if (attributes.lexicalEditor) anchor.parentElement.dataset.lexicalEditorRoot = ""

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

  test("preserves an explicit Turbo history action", () => {
    const anchor = document.getElementById("creative-link")
    anchor.dataset.turboAction = "replace"

    click("#creative-link")

    expect(visit).toHaveBeenCalledWith("/creatives/42?open_comments=true", {
      action: "replace",
      frame: WORKSPACE_FRAME_ID,
    })
  })

  test("keeps native navigation for a same-document fragment", () => {
    window.history.replaceState({}, "", "/creatives?id=42")
    document.getElementById("creative-link").setAttribute("href", "#creatives")

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(false)
    expect(visit).not.toHaveBeenCalled()
  })

  test("navigates a supported comment fragment through the workspace frame", () => {
    window.history.replaceState({}, "", "/creatives?id=42")
    document.getElementById("creative-link").setAttribute("href", "#comment_456")

    const event = click("#creative-link")

    expect(event.defaultPrevented).toBe(true)
    expect(visit).toHaveBeenCalledWith("#comment_456", {
      action: "advance",
      frame: WORKSPACE_FRAME_ID,
    })
  })
})
