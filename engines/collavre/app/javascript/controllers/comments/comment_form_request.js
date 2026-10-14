import { refreshCsrfToken } from '../../lib/api/csrf_fetch'

function parseCommentResponse(response) {
  if (response.ok) return response.text()
  return response.json().then((json) => {
    throw new Error(json.errors?.join(', ') || 'Unable to save comment')
  })
}

export function fetchCommentRequest(url, { method, body }) {
  return fetch(url, {
    method,
    headers: { 'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content },
    body,
  })
}

// The controller owns the existing retry flag and resets it when its UI settles.
// Keep refresh effects limited to HEAD; comment responses do not rotate the token.
export function parseCommentRequestResponse(response, retry, retryState) {
  if (response.status === 422 && !response.ok && !retryState._hasRetried) {
    retryState._hasRetried = true
    return refreshCsrfToken().then(retry).then(parseCommentResponse)
  }
  return parseCommentResponse(response)
}
