import csrfFetch, { refreshCsrfToken } from './api/csrf_fetch'

let pendingRequestController = null
const SEQUENCE_HEADER = 'X-Collavre-Last-Visited-Creative-Sequence'
const TOKEN_HEADER = 'X-Collavre-Last-Visited-Creative-Token'

function sequenceStorageKey() {
  return 'collavre:last-visited-creative-sequence'
}

function storedSequence() {
  try {
    return Number.parseInt(window.localStorage.getItem(sequenceStorageKey()), 10) || 0
  } catch (_) {
    return 0
  }
}

function storeSequence(sequence) {
  try {
    window.localStorage.setItem(sequenceStorageKey(), String(sequence))
  } catch (_) {
    // Private browsing can deny storage. The signed server sequence still
    // provides a safe baseline for this page.
  }
}

export function nextLastVisitedCreativeSequence(visitToken, currentSequence = 0) {
  const sequence = Math.max(storedSequence(), Number(currentSequence) || 0) + 1
  storeSequence(sequence)
  return sequence
}

export function prepareLastVisitedCreativeNavigation(event, visitToken, currentSequence) {
  const fetchOptions = event.detail?.fetchOptions
  if (!visitToken || !fetchOptions || String(fetchOptions.method || 'GET').toUpperCase() !== 'GET') return

  const headers = new Headers(fetchOptions.headers)
  headers.set(TOKEN_HEADER, visitToken)
  headers.set(SEQUENCE_HEADER, String(nextLastVisitedCreativeSequence(visitToken, currentSequence)))
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
  const sequence = nextLastVisitedCreativeSequence(visitToken, currentSequence)
  const url = new URL(baseUrl, window.location.origin)
  url.pathname = `${url.pathname.replace(/\/$/, '')}/${encodeURIComponent(creativeId)}/remember_last_visited`
  url.searchParams.set('visit_token', visitToken)
  const request = () => csrfFetch(`${url.pathname}${url.search}`, {
    method: 'PATCH',
    headers: {
      Accept: 'application/json',
      [SEQUENCE_HEADER]: String(sequence),
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
