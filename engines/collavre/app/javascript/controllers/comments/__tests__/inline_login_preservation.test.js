/** @jest-environment jsdom */
import { replaceCommentsPreservingLogins } from "../inline_login_preservation"

test("a chat refresh preserves the live form but changed or removed cards discard it", () => {
  global.CSS ||= { escape: value => value }
  const container = document.createElement("div")
  const html = '<turbo-frame id="inline_agent_login_123" src="/comments/123/agent-login"></turbo-frame>'
  container.innerHTML = html
  const frame = container.firstElementChild
  frame.setAttribute("src", new URL(frame.getAttribute("src"), document.baseURI).href)
  const input = document.createElement("input")
  input.value = "private-code"
  frame.append(input)
  replaceCommentsPreservingLogins(container, html + "<p>New message</p>")
  expect(container.firstElementChild).toBe(frame)
  expect(container.querySelector("input").value).toBe("private-code")
  expect(container.textContent).toContain("New message")
  replaceCommentsPreservingLogins(container, html.replace("/comments/123/", "/comments/456/"))
  expect(container.firstElementChild).not.toBe(frame)
  expect(container.querySelector("input")).toBeNull()
  replaceCommentsPreservingLogins(container, "<p>Deleted</p>")
  expect(container.querySelector("turbo-frame")).toBeNull()
})
