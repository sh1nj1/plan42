const DEFAULT_CREDENTIALS = 'same-origin'

function readCsrfToken() {
  if (typeof document === 'undefined') return null
  return document.querySelector('meta[name="csrf-token"]')?.content || null
}

/**
 * Update the page's CSRF meta tag with a fresh token from the server
 * response header.  This keeps the client-side token in sync when the
 * session cookie has been re-encrypted (e.g. after the browser was in
 * the background and a GET request refreshed the cookie).
 */
export function updateCsrfTokenFromResponse(response) {
  if (typeof document === 'undefined') return
  const freshToken = response.headers.get('X-CSRF-Token')
  if (!freshToken) return
  const meta = document.querySelector('meta[name="csrf-token"]')
  if (meta) meta.content = freshToken
}

/**
 * Fetch a fresh CSRF token from the server.  Uses a lightweight HEAD
 * request to the current page — the response body is discarded but the
 * X-CSRF-Token header gives us a valid token.
 */
export async function refreshCsrfToken() {
  try {
    const response = await fetch(window.location.href, {
      method: 'HEAD',
      credentials: 'same-origin',
    })
    updateCsrfTokenFromResponse(response)
    return readCsrfToken()
  } catch {
    return null
  }
}

export default function csrfFetch(input, options = {}) {
  const { headers: incomingHeaders, credentials, ...rest } = options
  const headers = new Headers(incomingHeaders || undefined)
  const token = readCsrfToken()

  if (token && !headers.has('X-CSRF-Token')) {
    headers.set('X-CSRF-Token', token)
  }

  return fetch(input, {
    credentials: credentials ?? DEFAULT_CREDENTIALS,
    headers,
    ...rest,
  }).then((response) => {
    updateCsrfTokenFromResponse(response)
    return response
  })
}
