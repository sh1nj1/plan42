export function isCreativeNavigation(url) {
  url = new URL(url, window.location.origin)

  return url.origin === window.location.origin && /\/creatives(?:\/|$)/.test(url.pathname)
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
