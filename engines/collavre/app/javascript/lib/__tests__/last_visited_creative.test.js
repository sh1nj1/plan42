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
})
