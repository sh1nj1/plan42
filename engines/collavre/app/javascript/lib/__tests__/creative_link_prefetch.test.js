/**
 * @jest-environment jsdom
 */
import { isCreativeVisitNavigation } from "../creative_link_prefetch"

function prefetch(link) {
  const event = new Event("turbo:before-prefetch", { bubbles: true, cancelable: true })
  link.dispatchEvent(event)
  return event
}

afterEach(() => {
  document.body.innerHTML = ""
})

test("prevents prefetching any same-origin Creative navigation link", () => {
  const links = [ "/creatives/1", "/collavre/creatives/2", "/workspace/creatives?id=3" ].map((href) => {
    const link = document.createElement("a")
    link.href = href
    document.body.appendChild(link)
    return link
  })

  links.forEach((link) => expect(prefetch(link).defaultPrevented).toBe(true))
})

test("does not prevent prefetching unrelated or external links", () => {
  const unrelated = document.createElement("a")
  unrelated.href = "/users/1"
  const external = document.createElement("a")
  external.href = "https://example.com/creatives/1"
  document.body.append(unrelated, external)

  expect(prefetch(unrelated).defaultPrevented).toBe(false)
  expect(prefetch(external).defaultPrevented).toBe(false)
})

test("identifies only Creative index and show routes as visit navigations", () => {
  [ "/creatives", "/creatives.html", "/collavre/creatives/2" ].forEach((url) => {
    expect(isCreativeVisitNavigation(url)).toBe(true)
  })

  ;[ "/creatives/2/comments/3/activity_log", "/creatives/next_last_visited_sequence" ].forEach((url) => {
    expect(isCreativeVisitNavigation(url)).toBe(false)
  })
})
