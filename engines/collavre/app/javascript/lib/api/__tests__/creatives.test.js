/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const csrfFetch = jest.fn()

jest.unstable_mockModule('../csrf_fetch', () => ({ default: csrfFetch }))

const creativesApi = await import('../creatives')

describe('creatives API workspace invalidation', () => {
  afterEach(() => {
    csrfFetch.mockReset()
  })

  test('invalidates the workspace tree after a successful mutation', async () => {
    const listener = jest.fn()
    document.addEventListener('workspace-tree:invalidate', listener)
    csrfFetch.mockResolvedValue({ ok: true })

    await creativesApi.destroy(42)

    expect(listener).toHaveBeenCalledTimes(1)
    document.removeEventListener('workspace-tree:invalidate', listener)
  })

  test('does not invalidate the workspace tree after a failed mutation', async () => {
    const listener = jest.fn()
    document.addEventListener('workspace-tree:invalidate', listener)
    csrfFetch.mockResolvedValue({ ok: false })

    await creativesApi.archive(42)

    expect(listener).not.toHaveBeenCalled()
    document.removeEventListener('workspace-tree:invalidate', listener)
  })
})
