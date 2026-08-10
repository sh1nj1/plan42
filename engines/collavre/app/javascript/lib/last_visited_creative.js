import csrfFetch, { refreshCsrfToken } from './api/csrf_fetch'

let pendingRequestController = null
const SEQUENCE_HEADER = 'X-Collavre-Last-Visited-Creative-Sequence'
const TOKEN_HEADER = 'X-Collavre-Last-Visited-Creative-Token'

function sequenceStorageKey() {
  return 'collavre:last-visited-creative-sequence'
}

export function nextLastVisitedCreativeSequence(currentSequence = 0) {
  try {
    const stored = Number.parseInt(window.localStorage.getItem(sequenceStorageKey()), 10) || 0
    const sequence = Math.max(stored, Number(currentSequence) || 0) + 1
    window.localStorage.setItem(sequenceStorageKey(), String(sequence))

    // A storage implementation can silently ignore writes. Only submit a
    // client sequence after confirming tabs can share it; otherwise Rails
    // allocates the sequence atomically while holding the user lock.
    return Number.parseInt(window.localStorage.getItem(sequenceStorageKey()), 10) === sequence ? sequence : null
  } catch (_) {
    return null
  }
}

export function prepareLastVisitedCreativeNavigation(event, visitToken, currentSequence) {
  const fetchOptions = event.detail?.fetchOptions
  if (!visitToken || !fetchOptions || String(fetchOptions.method || 'GET').toUpperCase() !== 'GET') return

  const headers = new Headers(fetchOptions.headers)
  headers.set(TOKEN_HEADER, visitToken)
  const sequence = nextLastVisitedCreativeSequence(currentSequence)
  if (sequence) headers.set(SEQUENCE_HEADER, String(sequence))
  fetchOptions.headers = headers
}

export function cancelPendingLastVisitedCreative() {
  pendingRequestController?.abort()
  pendingRequestController = null
}

export function rememberLastVisitedCreative(baseUrl, creativeId, visitToken, currentSequence) {
  if (!baseUrl || !creativeId || !visitToken) return

  cancelPendingLastVisitedCreative()
  const requestController = new AbortController()
  pendingRequestController = requestController
  const sequence = nextLastVisitedCreativeSequence(currentSequence)
  const url = new URL(baseUrl, window.location.origin)
  url.pathname = `${url.pathname.replace(/\/$/, '')}/${encodeURIComponent(creativeId)}/remember_last_visited`
  url.searchParams.set('visit_token', visitToken)
  const request = () => csrfFetch(`${url.pathname}${url.search}`, {
    method: 'PATCH',
    headers: {
      Accept: 'application/json',
      ...(sequence && { [SEQUENCE_HEADER]: String(sequence) }),
    },
    signal: requestController.signal,
  })

  request()
    .then(async (response) => {
      if (requestController.signal.aborted || response.ok || response.status !== 422) return

      await refreshCsrfToken({ signal: requestController.signal })
      if (requestController.signal.aborted) return
      await request()
    })
    .catch(() => {})
    .finally(() => {
      if (pendingRequestController === requestController) pendingRequestController = null
    })
}
