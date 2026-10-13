// Keep a page's testing override on every cache lookup, enqueue and poll.
export function translationLocaleUrl(path) {
  const lang = new URLSearchParams(window.location.search).get('lang')
  if (!lang) return path
  const url = new URL(path, window.location.origin)
  url.searchParams.set('lang', lang)
  return url.pathname + url.search
}
