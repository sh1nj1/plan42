/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'
import { refreshCsrfToken } from '../csrf_fetch'

describe('refreshCsrfToken', () => {
  afterEach(() => {
    delete global.fetch
  })

  test('marks the refresh as a prefetch and passes through cancellation', async () => {
    const signal = new AbortController().signal
    const fetchMock = jest.fn().mockResolvedValue({ headers: new Headers() })
    global.fetch = fetchMock

    await refreshCsrfToken({ signal })

    expect(fetchMock).toHaveBeenCalledWith(window.location.href, {
      method: 'HEAD',
      credentials: 'same-origin',
      headers: { 'X-Sec-Purpose': 'prefetch' },
      signal,
    })
  })
})
