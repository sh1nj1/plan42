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
  nextLastVisitedCreativeSequence,
  rememberLastVisitedCreative,
} = await import('../last_visited_creative')

describe('nextLastVisitedCreativeSequence', () => {
  test('defers sequence allocation to Rails when localStorage is unavailable', () => {
    const localStorageGetter = jest.spyOn(window, 'localStorage', 'get').mockImplementation(() => {
      throw new DOMException('Access denied', 'SecurityError')
    })

    expect(nextLastVisitedCreativeSequence(1)).toBeNull()
    expect(nextLastVisitedCreativeSequence(1)).toBeNull()

    localStorageGetter.mockRestore()
  })
})

describe('rememberLastVisitedCreative', () => {
  beforeEach(() => {
    csrfFetch.mockReset()
    refreshCsrfToken.mockReset()
    window.localStorage.clear()
  })

  test('cancels the CSRF refresh when a newer visit supersedes a restored visit', async () => {
    csrfFetch.mockResolvedValue({ ok: true }).mockResolvedValueOnce({ ok: false, status: 422 })
    refreshCsrfToken.mockImplementationOnce(({ signal }) => new Promise((resolve) => {
      signal.addEventListener('abort', resolve, { once: true })
    }))

    rememberLastVisitedCreative('/creatives', 1, 'restored-token', 1)
    await Promise.resolve()
    rememberLastVisitedCreative('/creatives', 2, 'newer-token', 2)

    expect(refreshCsrfToken).toHaveBeenCalledWith(expect.objectContaining({ signal: expect.any(AbortSignal) }))
    expect(csrfFetch).toHaveBeenCalledTimes(2)
  })
})
