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

  test('creates a rich-authored Markdown creative from a picker title', async () => {
    const listener = jest.fn()
    document.addEventListener('workspace-tree:invalidate', listener)
    csrfFetch.mockResolvedValue({ ok: true, json: () => Promise.resolve({ id: 17 }) })

    await expect(creativesApi.createFromTitle('New page')).resolves.toEqual({ id: 17 })

    const [, options] = csrfFetch.mock.calls[0]
    expect(csrfFetch.mock.calls[0][0]).toBe('/creatives')
    expect(options.method).toBe('POST')
    expect(options.body.get('creative[markdown_source]')).toBe('New page')
    expect(options.body.get('creative[content_type_input]')).toBe('markdown')
    expect(options.body.get('creative[markdown_editor]')).toBe('rich')
    expect(listener).toHaveBeenCalledTimes(1)
    document.removeEventListener('workspace-tree:invalidate', listener)
  })

  test('rejects a failed picker creation without invalidating the workspace tree', async () => {
    const listener = jest.fn()
    document.addEventListener('workspace-tree:invalidate', listener)
    csrfFetch.mockResolvedValue({ ok: false, status: 422 })

    await expect(creativesApi.createFromTitle('Invalid')).rejects.toThrow(
      'Failed to create creative: 422',
    )
    expect(listener).not.toHaveBeenCalled()
    document.removeEventListener('workspace-tree:invalidate', listener)
  })
})
