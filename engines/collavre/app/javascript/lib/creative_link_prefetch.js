export function isCreativeNavigation(url) {
  url = new URL(url, window.location.origin)

  return url.origin === window.location.origin && /\/creatives(?:\/|$)/.test(url.pathname)
}

// Only these HTML routes reach CreativesController#index visit persistence:
// the Creative index and a single Creative show route (which redirects there).
// Nested Creative routes load supporting UI and must not reserve a visit
// sequence merely because a last-visited controller is connected.
export function isCreativeVisitNavigation(url) {
  url = new URL(url, window.location.origin)

  return url.origin === window.location.origin && /\/creatives(?:\.html|\/\d+)?\/?$/.test(url.pathname)
}

export function preventCreativeLinkPrefetch(event) {
  const link = event.target
  if (!(link instanceof HTMLAnchorElement) || !isCreativeNavigation(link.href)) return

  event.preventDefault()
}

// A prefetched Creative response can be promoted by Turbo without issuing a
// second request. Prevent it globally so confirmed navigation remains the only
// way to update the user's last visited Creative, regardless of link source.
document.addEventListener("turbo:before-prefetch", preventCreativeLinkPrefetch)
