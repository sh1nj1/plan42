const DEFAULT_CREDENTIALS = 'same-origin'

function readCsrfToken() {
  if (typeof document === 'undefined') return null
  return document.querySelector('meta[name="csrf-token"]')?.content || null
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
  })
}
