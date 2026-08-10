import csrfFetch, { refreshCsrfToken } from './api/csrf_fetch'
import { LAST_VISITED_CREATIVE_AT_HEADER, nextLastVisitedCreativeTimestamp } from './creative_link_prefetch'

let pendingRequestController = null

export function cancelPendingLastVisitedCreative() {
  pendingRequestController?.abort()
  pendingRequestController = null
}

export function rememberLastVisitedCreative(baseUrl, creativeId) {
  if (!baseUrl || !creativeId) return

  cancelPendingLastVisitedCreative()
  const requestController = new AbortController()
  pendingRequestController = requestController
  const visitTimestamp = String(nextLastVisitedCreativeTimestamp())
  const url = new URL(baseUrl, window.location.origin)
  url.pathname = `${url.pathname.replace(/\/$/, '')}/${encodeURIComponent(creativeId)}/remember_last_visited`
  const request = () => csrfFetch(`${url.pathname}${url.search}`, {
    method: 'PATCH',
    headers: {
      Accept: 'application/json',
      [LAST_VISITED_CREATIVE_AT_HEADER]: visitTimestamp,
    },
    signal: requestController.signal,
  })

  request()
    .then(async (response) => {
      if (requestController.signal.aborted || response.ok || response.status !== 422) return

      await refreshCsrfToken()
      if (requestController.signal.aborted) return
      await request()
    })
    .catch(() => {})
    .finally(() => {
      if (pendingRequestController === requestController) pendingRequestController = null
    })
}
