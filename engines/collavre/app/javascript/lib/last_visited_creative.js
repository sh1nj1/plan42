import csrfFetch, { refreshCsrfToken } from './api/csrf_fetch'

export function rememberLastVisitedCreative(baseUrl, creativeId) {
  if (!baseUrl || !creativeId) return

  const url = new URL(baseUrl, window.location.origin)
  url.pathname = `${url.pathname.replace(/\/$/, '')}/${encodeURIComponent(creativeId)}/remember_last_visited`
  const request = () => csrfFetch(`${url.pathname}${url.search}`, {
    method: 'PATCH',
    headers: { Accept: 'application/json' },
  })

  request()
    .then(async (response) => {
      if (response.ok || response.status !== 422) return

      await refreshCsrfToken()
      await request()
    })
    .catch(() => {})
}
