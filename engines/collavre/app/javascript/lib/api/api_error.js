/**
 * Shared API error handling.
 *
 * Server endpoints report failures as JSON, most commonly the Rails shape
 * `{ "errors": ["..."] }` (see CreativesController#update). When a request
 * fails we want the user to see the *server's* message ("Description cannot be
 * changed directly for GitHub synced content") rather than an opaque
 * "HTTP 422". This module centralises that extraction so every API caller can
 * surface the real reason with a generic fallback.
 */

/**
 * Error carrying the parsed server payload alongside the HTTP status.
 * `errors` is always an array of human-readable strings (possibly empty).
 */
export class ApiError extends Error {
  constructor(message, { status, statusText, errors = [], payload = null } = {}) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.statusText = statusText
    this.errors = errors
    this.payload = payload
  }
}

function stringifyEntry(entry) {
  if (typeof entry === 'string') return entry.trim()
  if (entry && typeof entry === 'object') {
    return String(entry.message || entry.detail || entry.title || '').trim()
  }
  return ''
}

/**
 * Normalise the assorted server error payload shapes into a flat list of
 * human-readable strings.
 *
 * Supported shapes:
 *   { errors: ["a", "b"] }                 -> ["a", "b"]
 *   { errors: { field: ["a"], x: ["b"] } } -> ["a", "b"]  (Rails errors hash)
 *   { errors: [{ message: "a" }] }         -> ["a"]
 *   { error: "a" } / { message: "a" }      -> ["a"]
 */
export function extractServerErrors(payload) {
  if (!payload || typeof payload !== 'object') return []

  const { errors } = payload
  if (Array.isArray(errors)) {
    return errors.map(stringifyEntry).filter(Boolean)
  }
  if (errors && typeof errors === 'object') {
    return Object.values(errors).flat().map(stringifyEntry).filter(Boolean)
  }
  if (typeof payload.error === 'string' && payload.error.trim()) {
    return [payload.error.trim()]
  }
  if (typeof payload.message === 'string' && payload.message.trim()) {
    return [payload.message.trim()]
  }
  return []
}

/**
 * Build an {@link ApiError} from a non-ok Response, reading and parsing its
 * body. Best-effort: an empty or non-JSON body yields an error that falls back
 * to the HTTP status line. Consumes the response body, so only call this on the
 * failure path.
 *
 * @param {Response} response
 * @returns {Promise<ApiError>}
 */
export async function apiErrorFromResponse(response) {
  let payload = null
  try {
    const text = typeof response.text === 'function' ? await response.text() : ''
    payload = text ? JSON.parse(text) : null
  } catch (_parseError) {
    payload = null
  }

  const errors = extractServerErrors(payload)
  const message = errors.length
    ? errors.join('\n')
    : `HTTP ${response.status}: ${response.statusText}`

  return new ApiError(message, {
    status: response.status,
    statusText: response.statusText,
    errors,
    payload,
  })
}

/**
 * Best user-facing message for a caught error: the server-provided messages
 * when available, otherwise `null` so the caller can apply its own generic
 * fallback copy.
 *
 * @param {unknown} error
 * @returns {string|null}
 */
export function serverErrorMessage(error) {
  if (error && Array.isArray(error.errors) && error.errors.length) {
    return error.errors.join('\n')
  }
  return null
}
