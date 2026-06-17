/**
 * @jest-environment jsdom
 */
import { ApiError, apiErrorFromResponse, serverErrorMessage } from '../api_error'

// Minimal Response-like stub: text() resolves once with the given body.
function fakeResponse({ status = 422, statusText = 'Unprocessable Entity', body = '' } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText,
    text: async () => body,
  }
}

describe('apiErrorFromResponse', () => {
  test('surfaces a Rails {errors: [...]} string array as the message', async () => {
    const response = fakeResponse({
      body: JSON.stringify({
        errors: ['Description cannot be changed directly for GitHub synced content'],
      }),
    })

    const error = await apiErrorFromResponse(response)

    expect(error).toBeInstanceOf(ApiError)
    expect(error.status).toBe(422)
    expect(error.errors).toEqual([
      'Description cannot be changed directly for GitHub synced content',
    ])
    expect(error.message).toBe(
      'Description cannot be changed directly for GitHub synced content',
    )
  })

  test('joins multiple error messages with newlines', async () => {
    const response = fakeResponse({
      body: JSON.stringify({ errors: ['First problem', 'Second problem'] }),
    })

    const error = await apiErrorFromResponse(response)

    expect(error.errors).toEqual(['First problem', 'Second problem'])
    expect(error.message).toBe('First problem\nSecond problem')
  })

  test('flattens a Rails hash-style {errors: {field: [...]}} payload', async () => {
    const response = fakeResponse({
      body: JSON.stringify({ errors: { description: ['is invalid', 'is too long'] } }),
    })

    const error = await apiErrorFromResponse(response)

    expect(error.errors).toEqual(['is invalid', 'is too long'])
  })

  test('supports a singular {error: "..."} payload', async () => {
    const response = fakeResponse({ status: 403, body: JSON.stringify({ error: 'Forbidden' }) })

    const error = await apiErrorFromResponse(response)

    expect(error.errors).toEqual(['Forbidden'])
    expect(error.message).toBe('Forbidden')
  })

  test('falls back to HTTP status when the body has no usable payload', async () => {
    const response = fakeResponse({ status: 500, statusText: 'Internal Server Error', body: '' })

    const error = await apiErrorFromResponse(response)

    expect(error.errors).toEqual([])
    expect(error.message).toBe('HTTP 500: Internal Server Error')
  })

  test('falls back to HTTP status when the body is not JSON', async () => {
    const response = fakeResponse({ status: 502, statusText: 'Bad Gateway', body: '<html>oops</html>' })

    const error = await apiErrorFromResponse(response)

    expect(error.errors).toEqual([])
    expect(error.message).toBe('HTTP 502: Bad Gateway')
  })
})

describe('serverErrorMessage', () => {
  test('returns the joined server messages when present', () => {
    const error = new ApiError('boom', { errors: ['Bad thing', 'Worse thing'] })
    expect(serverErrorMessage(error)).toBe('Bad thing\nWorse thing')
  })

  test('returns null for a plain error with no server payload', () => {
    expect(serverErrorMessage(new Error('HTTP 422: Unprocessable Entity'))).toBeNull()
    expect(serverErrorMessage(new ApiError('boom', { errors: [] }))).toBeNull()
    expect(serverErrorMessage(undefined)).toBeNull()
  })
})
