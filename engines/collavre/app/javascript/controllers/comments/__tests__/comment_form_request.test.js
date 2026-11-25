/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { fetchCommentRequest, parseCommentRequestResponse } from '../comment_form_request'

function submitCommentRequest(url, options, state) {
  const doFetch = () => fetchCommentRequest(url, options)
  return doFetch().then((response) => parseCommentRequestResponse(response, doFetch, state))
}

describe('comment form HTTP boundary', () => {
  let state
  let body
  const errorResponse = (status, errors) => ({ ok: false, status, json: async () => ({ errors }) })
  const success = (html = 'comment') => ({ ok: true, status: 200, text: async () => html })

  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="initial">'
    state = {}
    body = new FormData()
    global.fetch = jest.fn()
  })

  test.each(['POST', 'PATCH'])('parses %s success without changing response token effects', async (method) => {
    global.fetch.mockResolvedValue({ ...success(), headers: new Headers({ 'X-CSRF-Token': 'ignored' }) })
    await expect(submitCommentRequest('/comments', { method, body }, state)).resolves.toBe('comment')
    expect(global.fetch).toHaveBeenCalledWith('/comments', {
      method, body, headers: { 'X-CSRF-Token': 'initial' },
    })
    expect(document.querySelector('meta').content).toBe('initial')
  })

  test('refreshes once and stops on repeated 422', async () => {
    global.fetch.mockResolvedValueOnce(errorResponse(422, ['stale']))
      .mockResolvedValueOnce({ headers: new Headers({ 'X-CSRF-Token': 'fresh' }) })
      .mockResolvedValueOnce(errorResponse(422, ['still invalid', 'missing']))
    await expect(submitCommentRequest('/comments', { method: 'POST', body }, state))
      .rejects.toThrow('still invalid, missing')
    expect(global.fetch).toHaveBeenCalledTimes(3)
    expect(global.fetch.mock.calls[2][1].body).toBe(body)
    expect(global.fetch.mock.calls[2][1].headers['X-CSRF-Token']).toBe('fresh')
    expect(state._hasRetried).toBe(true)
  })

  test('preserves shared controller retry flag and leaves reset to caller', async () => {
    state._hasRetried = true
    global.fetch.mockResolvedValue(errorResponse(422, ['invalid']))
    await expect(submitCommentRequest('/comments', { method: 'POST', body }, state)).rejects.toThrow('invalid')
    expect(global.fetch).toHaveBeenCalledTimes(1)
    expect(state._hasRetried).toBe(true)
  })

  test('uses fallback error for non-422 failures without refreshing', async () => {
    global.fetch.mockResolvedValue(errorResponse(403))
    await expect(submitCommentRequest('/comments', { method: 'POST', body }, state)).rejects.toThrow('Unable to save comment')
    expect(global.fetch).toHaveBeenCalledTimes(1)
  })

  test('still retries when token refresh fails', async () => {
    global.fetch.mockResolvedValueOnce(errorResponse(422))
      .mockRejectedValueOnce(new Error('offline HEAD'))
      .mockResolvedValueOnce(success())
    await expect(submitCommentRequest('/comments', { method: 'POST', body }, state)).resolves.toBe('comment')
    expect(global.fetch.mock.calls[2][1].headers['X-CSRF-Token']).toBe('initial')
  })

  test('propagates fetch and JSON parsing errors', async () => {
    global.fetch.mockRejectedValueOnce(new Error('offline'))
    await expect(submitCommentRequest('/comments', { method: 'POST', body }, state)).rejects.toThrow('offline')
    global.fetch.mockResolvedValueOnce({ ok: false, status: 500, json: async () => { throw new Error('invalid JSON') } })
    await expect(submitCommentRequest('/comments', { method: 'POST', body }, state)).rejects.toThrow('invalid JSON')
  })
})
