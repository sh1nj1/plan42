export const LAST_VISITED_CREATIVE_AT_HEADER = "X-Collavre-Last-Visited-Creative-At"

let lastVisitTimestamp = 0

export function nextLastVisitedCreativeTimestamp() {
  lastVisitTimestamp = Math.max(Date.now(), lastVisitTimestamp + 1)
  return lastVisitTimestamp
}

export function isCreativeNavigation(url) {
  url = new URL(url, window.location.origin)

  return url.origin === window.location.origin && /\/creatives(?:\/|$)/.test(url.pathname)
}

export function preventCreativeLinkPrefetch(event) {
  const link = event.target
  if (!(link instanceof HTMLAnchorElement) || !isCreativeNavigation(link.href)) return

  event.preventDefault()
}

export function orderCreativeNavigationRequest(event) {
  const { url, fetchOptions } = event.detail || {}
  if (!url || !fetchOptions || !isCreativeNavigation(url)) return

  const timestamp = String(nextLastVisitedCreativeTimestamp())
  const headers = fetchOptions.headers || (fetchOptions.headers = {})
  if (headers instanceof Headers) {
    headers.set(LAST_VISITED_CREATIVE_AT_HEADER, timestamp)
  } else {
    headers[LAST_VISITED_CREATIVE_AT_HEADER] = timestamp
  }
}

// A prefetched Creative response can be promoted by Turbo without issuing a
// second request. Prevent it globally so confirmed navigation remains the only
// way to update the user's last visited Creative, regardless of link source.
document.addEventListener("turbo:before-prefetch", preventCreativeLinkPrefetch)
document.addEventListener("turbo:before-fetch-request", orderCreativeNavigationRequest)
