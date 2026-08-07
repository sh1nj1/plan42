/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

jest.unstable_mockModule('../../../creatives/tree_renderer', () => ({
  renderCreativeTree: jest.fn(),
  appendCreativeNodes: jest.fn(),
  dispatchCreativeTreeUpdated: jest.fn(),
  applyRowProperties: jest.fn(),
}))

jest.unstable_mockModule('../../../utils/emoji_parser', () => ({
  parseEmojis: jest.fn(() => ['✨']),
}))

const { Application } = await import('@hotwired/stimulus')
const TreeController = (await import('../tree_controller')).default
const { appendCreativeNodes } = await import('../../../creatives/tree_renderer')
const { restoreTreeEmptyState } = await import('../../../modules/creative_tree_empty_state')

const TRANSIENT_RETRY_DELAYS = [200, 600]

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

const collectRetryDelays = (spy) =>
  spy.mock.calls
    .map((args) => args[1])
    .filter((delay) => TRANSIENT_RETRY_DELAYS.includes(delay))

const installController = () => {
  const container = document.createElement('div')
  container.setAttribute('data-controller', 'creatives--tree')
  container.setAttribute('data-creatives--tree-url-value', '/creatives?format=json&id=991')
  document.body.appendChild(container)

  const application = Application.start()
  application.register('creatives--tree', TreeController)

  return { container, application }
}

describe('CreativesTreeController retry on transient network errors', () => {
  let originalFetch
  let setTimeoutSpy

  beforeEach(() => {
    originalFetch = global.fetch
    setTimeoutSpy = jest.spyOn(global, 'setTimeout')
  })

  afterEach(() => {
    setTimeoutSpy.mockRestore()
    global.fetch = originalFetch
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('schedules 200ms then 600ms backoff retry on TypeError "Failed to fetch"', async () => {
    global.fetch = jest
      .fn()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [] }),
      })

    const { application } = installController()
    // Allow time for the 200ms + 600ms retries to fire
    await new Promise((resolve) => setTimeout(resolve, 1000))

    expect(collectRetryDelays(setTimeoutSpy)).toEqual(TRANSIENT_RETRY_DELAYS)

    application.stop()
  })

  test('does NOT schedule retry on HTTP error responses', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 500,
      json: async () => ({}),
    })

    const { application } = installController()
    await flush()
    await flush()
    await flush()

    expect(collectRetryDelays(setTimeoutSpy)).toEqual([])

    application.stop()
  })

  test('does NOT schedule retry on AbortError', async () => {
    const abortErr = new Error('aborted')
    abortErr.name = 'AbortError'
    global.fetch = jest.fn().mockRejectedValue(abortErr)

    const { application } = installController()
    await flush()
    await flush()

    expect(collectRetryDelays(setTimeoutSpy)).toEqual([])

    application.stop()
  })

  test('gives up after exactly 2 retries on persistent transient errors', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch = jest.fn().mockRejectedValue(new TypeError('Failed to fetch'))

    const { application } = installController()
    // Allow time for both retries to complete (200 + 600 = 800ms)
    await new Promise((resolve) => setTimeout(resolve, 1500))

    expect(collectRetryDelays(setTimeoutSpy)).toEqual(TRANSIENT_RETRY_DELAYS)

    application.stop()
  })
})

describe('CreativesTreeController Chats pagination (load more)', () => {
  let originalFetch
  let originalIO

  class MockIntersectionObserver {
    constructor(callback) {
      this.callback = callback
      MockIntersectionObserver.instances.push(this)
    }
    observe(el) { this.observed = el }
    disconnect() { this.disconnected = true }
    triggerIntersect() { this.callback([{ isIntersecting: true }]) }
  }

  beforeEach(() => {
    originalFetch = global.fetch
    originalIO = global.IntersectionObserver
    MockIntersectionObserver.instances = []
    global.IntersectionObserver = MockIntersectionObserver
    appendCreativeNodes.mockClear()
  })

  afterEach(() => {
    global.fetch = originalFetch
    global.IntersectionObserver = originalIO
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('observes a sentinel only when the response carries has_more pagination', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
    })

    const { container, application } = installController()
    await flush()
    await flush()

    expect(MockIntersectionObserver.instances).toHaveLength(1)
    expect(container.querySelector('.creative-chats-load-sentinel')).not.toBeNull()

    application.stop()
  })

  test('does NOT set up pagination for a plain tree response (no pagination key)', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ creatives: [{ id: 1 }] }),
    })

    const { container, application } = installController()
    await flush()
    await flush()

    expect(MockIntersectionObserver.instances).toHaveLength(0)
    expect(container.querySelector('.creative-chats-load-sentinel')).toBeNull()

    application.stop()
  })

  test('fetches the next page and appends rows when the sentinel intersects', async () => {
    const page2Nodes = [{ id: 2 }, { id: 3 }]
    global.fetch = jest
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: page2Nodes, pagination: { has_more: false, next_page: null } }),
      })

    const { application } = installController()
    await flush()
    await flush()

    const observer = MockIntersectionObserver.instances[0]
    observer.triggerIntersect()
    await flush()
    await flush()

    const secondCallUrl = global.fetch.mock.calls[1][0]
    expect(secondCallUrl).toContain('page=2')
    expect(appendCreativeNodes).toHaveBeenCalledTimes(1)
    expect(appendCreativeNodes.mock.calls[0][1]).toEqual(page2Nodes)
    // has_more:false on page 2 tears the observer down.
    expect(observer.disconnected).toBe(true)

    application.stop()
  })

  test('drops a stale load-more response that resolves after a fresh load', async () => {
    let resolvePage2
    const page2Nodes = [{ id: 2 }, { id: 3 }]
    global.fetch = jest
      .fn()
      // initial page-1 (Chats filter, has more)
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })
      // page-2 stays pending until we resolve it manually
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolvePage2 = () =>
              resolve({
                ok: true,
                json: async () => ({ creatives: page2Nodes, pagination: { has_more: true, next_page: 3 } }),
              })
          })
      )
      // the fresh load() re-renders a different (non-paginated) view
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [{ id: 99 }] }),
      })

    const { container, application } = installController()
    await flush()
    await flush()

    // Sentinel intersects -> page-2 fetch kicks off but stays pending.
    MockIntersectionObserver.instances[0].triggerIntersect()
    await flush()

    // A fresh load happens before page 2 resolves (filter change, sync refetch,
    // archive toggle). load() tears down pagination and aborts the in-flight
    // load-more.
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller.load()
    await flush()
    await flush()

    // The stale page-2 response finally arrives. It must NOT be appended into
    // the freshly rendered view.
    resolvePage2()
    await flush()
    await flush()

    expect(appendCreativeNodes).not.toHaveBeenCalled()

    application.stop()
  })

  // Deleting every row that is currently on screen does not mean the feed is
  // empty when further pages are still queued behind the sentinel. Restoring the
  // placeholder there both lies and outlives the append, leaving "No creatives
  // found." sitting above the rows the next page brings in.
  describe('empty-state placeholder vs. queued pages', () => {
    const installEmptyStateTemplate = () => {
      const template = document.createElement('template')
      template.id = 'creatives-empty-state-template'
      template.innerHTML = '<p data-creatives-empty-state>No creatives found.</p>'
      document.body.appendChild(template)
      return template
    }

    test('suppresses the placeholder while the feed has more pages queued', async () => {
      installEmptyStateTemplate()
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })

      const { container, application } = installController()
      await flush()
      await flush()

      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(true)

      // The user batch-deletes every rendered row; removeTreeElement asks for the
      // placeholder back.
      restoreTreeEmptyState(container)

      expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()

      application.stop()
    })

    test('restores the placeholder once the last page lands and nothing is left', async () => {
      installEmptyStateTemplate()
      global.fetch = jest
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [], pagination: { has_more: false, next_page: null } }),
        })

      const { container, application } = installController()
      await flush()
      await flush()

      restoreTreeEmptyState(container)
      expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()

      MockIntersectionObserver.instances[0].triggerIntersect()
      await flush()
      await flush()

      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(false)
      const placeholder = container.querySelector('[data-creatives-empty-state]')
      expect(placeholder).not.toBeNull()
      expect(placeholder.hidden).toBe(false)

      application.stop()
    })

    test('hides a placeholder that is on screen when the next page is appended', async () => {
      installEmptyStateTemplate()
      global.fetch = jest
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [{ id: 2 }], pagination: { has_more: true, next_page: 3 } }),
        })

      const { container, application } = installController()
      await flush()
      await flush()

      // Belt and braces: a placeholder that got in anyway (a path that predates
      // the pending marker) must not survive the append.
      const stray = document.createElement('p')
      stray.setAttribute('data-creatives-empty-state', '')
      container.appendChild(stray)

      MockIntersectionObserver.instances[0].triggerIntersect()
      await flush()
      await flush()

      expect(appendCreativeNodes).toHaveBeenCalledTimes(1)
      expect(stray.hidden).toBe(true)

      application.stop()
    })

    test('clears the pending marker when a fresh load tears pagination down', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })

      const { container, application } = installController()
      await flush()
      await flush()
      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(true)

      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ creatives: [{ id: 9 }] }),
      })
      application.getControllerForElementAndIdentifier(container, 'creatives--tree').load()
      await flush()
      await flush()

      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(false)

      application.stop()
    })
  })
})
