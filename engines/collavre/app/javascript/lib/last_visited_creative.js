import csrfFetch, { refreshCsrfToken } from './api/csrf_fetch'
import { isCreativeNavigation } from './creative_link_prefetch'

let pendingRequestController = null
const SEQUENCE_HEADER = 'X-Collavre-Last-Visited-Creative-Sequence'
const TOKEN_HEADER = 'X-Collavre-Last-Visited-Creative-Token'

function sequenceUrl(baseUrl) {
  const url = new URL(baseUrl, window.location.origin)
  url.pathname = `${url.pathname.replace(/\/$/, '')}/next_last_visited_sequence`
  return `${url.pathname}${url.search}`
}

async function nextLastVisitedCreativeSequence(baseUrl, signal) {
  const response = await csrfFetch(sequenceUrl(baseUrl), {
    method: 'PATCH',
    headers: { Accept: 'application/json' },
    signal,
  })
  if (!response.ok) return null

  const sequence = Number((await response.json()).sequence)
  return Number.isSafeInteger(sequence) && sequence > 0 ? sequence : null
}

export async function prepareLastVisitedCreativeNavigation(event, baseUrl, visitToken) {
  const fetchOptions = event.detail?.fetchOptions
  if (
    !baseUrl ||
    !visitToken ||
    !fetchOptions ||
    !isCreativeNavigation(event.detail?.url) ||
    String(fetchOptions.method || 'GET').toUpperCase() !== 'GET'
  ) return

  event.preventDefault()
  try {
    const sequence = await nextLastVisitedCreativeSequence(baseUrl)
    if (!sequence) return

    const headers = new Headers(fetchOptions.headers)
    headers.set(TOKEN_HEADER, visitToken)
    headers.set(SEQUENCE_HEADER, String(sequence))
    fetchOptions.headers = headers
  } finally {
    event.detail.resume?.()
  }
}

export function cancelPendingLastVisitedCreative() {
  pendingRequestController?.abort()
  pendingRequestController = null
}

export function rememberLastVisitedCreative(baseUrl, creativeId, visitToken) {
  if (!baseUrl || !creativeId || !visitToken) return

  cancelPendingLastVisitedCreative()
  const requestController = new AbortController()
  pendingRequestController = requestController
  const url = new URL(baseUrl, window.location.origin)
  url.pathname = `${url.pathname.replace(/\/$/, '')}/${encodeURIComponent(creativeId)}/remember_last_visited`
  url.searchParams.set('visit_token', visitToken)
  const request = (sequence) => csrfFetch(`${url.pathname}${url.search}`, {
    method: 'PATCH',
    headers: {
      Accept: 'application/json',
      [SEQUENCE_HEADER]: String(sequence),
    },
    signal: requestController.signal,
  })

  nextLastVisitedCreativeSequence(baseUrl, requestController.signal)
    .then(async (sequence) => {
      if (!sequence || requestController.signal.aborted) return null
      return request(sequence)
    })
    .then(async (response) => {
      if (!response) return
      if (requestController.signal.aborted || response.ok || response.status !== 422) return

      await refreshCsrfToken({ signal: requestController.signal })
      if (requestController.signal.aborted) return
      const sequence = await nextLastVisitedCreativeSequence(baseUrl, requestController.signal)
      if (!sequence || requestController.signal.aborted) return
      await request(sequence)
    })
    .catch(() => {})
    .finally(() => {
      if (pendingRequestController === requestController) pendingRequestController = null
    })
}
