/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const csrfFetch = jest.fn()
const refreshCsrfToken = jest.fn()

jest.unstable_mockModule('../api/csrf_fetch', () => ({
  default: csrfFetch,
  refreshCsrfToken,
}))

const {
  prepareLastVisitedCreativeNavigation,
  rememberLastVisitedCreative,
} = await import('../last_visited_creative')

describe('rememberLastVisitedCreative', () => {
  beforeEach(() => {
    csrfFetch.mockReset()
    refreshCsrfToken.mockReset()
  })

  test('cancels the CSRF refresh when a newer visit supersedes a restored visit', async () => {
    csrfFetch
      .mockResolvedValue({ ok: true, json: async () => ({ sequence: 3 }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sequence: 2 }) })
      .mockResolvedValueOnce({ ok: false, status: 422 })
    refreshCsrfToken.mockImplementationOnce(({ signal }) => new Promise((resolve) => {
      signal.addEventListener('abort', resolve, { once: true })
    }))

    rememberLastVisitedCreative('/creatives', 1, 'restored-token')
    await new Promise((resolve) => setTimeout(resolve, 0))
    rememberLastVisitedCreative('/creatives', 2, 'newer-token')

    expect(refreshCsrfToken).toHaveBeenCalledWith(expect.objectContaining({ signal: expect.any(AbortSignal) }))
    expect(csrfFetch).toHaveBeenCalledWith('/creatives/next_last_visited_sequence', expect.objectContaining({ method: 'PATCH' }))
  })

  test('refreshes CSRF and retries sequence reservation before remembering a restored Creative', async () => {
    csrfFetch
      .mockResolvedValueOnce({ ok: false, status: 422 })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ sequence: 2 }) })
      .mockResolvedValueOnce({ ok: true })

    rememberLastVisitedCreative('/creatives', 1, 'restored-token')
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(refreshCsrfToken).toHaveBeenCalledWith(expect.objectContaining({ signal: expect.any(AbortSignal) }))
    expect(csrfFetch).toHaveBeenNthCalledWith(1, '/creatives/next_last_visited_sequence', expect.objectContaining({ method: 'PATCH' }))
    expect(csrfFetch).toHaveBeenNthCalledWith(2, '/creatives/next_last_visited_sequence', expect.objectContaining({ method: 'PATCH' }))
    expect(csrfFetch).toHaveBeenNthCalledWith(3, '/creatives/1/remember_last_visited?visit_token=restored-token', expect.objectContaining({ method: 'PATCH' }))
  })

  test('does not reserve a sequence for an unrelated Turbo navigation', async () => {
    const fetchOptions = { method: 'GET', headers: new Headers() }
    const resume = jest.fn()
    const event = new CustomEvent('turbo:before-fetch-request', {
      cancelable: true,
      detail: { fetchOptions, resume, url: '/users' },
    })

    await prepareLastVisitedCreativeNavigation(event, '/creatives', 'server-token')

    expect(event.defaultPrevented).toBe(false)
    expect(resume).not.toHaveBeenCalled()
    expect(csrfFetch).not.toHaveBeenCalled()
  })

  test('does not reserve a sequence for a nested Creative Turbo frame request', async () => {
    const fetchOptions = { method: 'GET', headers: new Headers() }
    const resume = jest.fn()
    const event = new CustomEvent('turbo:before-fetch-request', {
      cancelable: true,
      detail: { fetchOptions, resume, url: '/creatives/1/comments/2/activity_log' },
    })

    await prepareLastVisitedCreativeNavigation(event, '/creatives', 'server-token')

    expect(event.defaultPrevented).toBe(false)
    expect(resume).not.toHaveBeenCalled()
    expect(csrfFetch).not.toHaveBeenCalled()
  })
})
