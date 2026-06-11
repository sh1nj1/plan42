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
})
