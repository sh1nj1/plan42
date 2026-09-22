/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import ExpansionController from '../creatives/expansion_controller'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('creative expansion persistence', () => {
  let controller
  let row
  let children
  let toggleFetch
  let fenceSequence = 0
  beforeEach(() => {
    document.body.innerHTML = '<section><creative-tree-row creative-id="1"></creative-tree-row><div id="creative-children-1" data-loaded="true"><creative-tree-row creative-id="2"></creative-tree-row></div></section>'
    controller = Object.create(ExpansionController.prototype)
    Object.defineProperty(controller, 'element', { value: document.querySelector('section') })
    Object.defineProperty(controller, 'hasExpandTarget', { value: false })
    document.body.dataset.currentUserId = '10'
    controller.userId = '10'
    controller.rowIntents = new WeakMap()
    controller.saveQueue = Promise.resolve()
    controller.currentCreativeId = null
    window.history.replaceState({}, '', '/creatives')
    controller.allExpanded = false
    row = document.querySelector('creative-tree-row')
    row.hasChildren = true
    children = document.querySelector('#creative-children-1')
    toggleFetch = jest.fn().mockResolvedValue({ ok: true, headers: new Headers(), json: async () => ({ success: true }) })
    global.fetch = (url, options) => url.endsWith('/fence')
      ? Promise.resolve({ ok: true, headers: new Headers(), json: async () => ({ expansion_save_fence: ++fenceSequence }) })
      : toggleFetch(url, options)
  })

  test('expand all persists branches including asynchronously inserted descendants', async () => {
    controller.toggleAll({ preventDefault() {} })
    await flush()
    await controller.saveQueue
    expect(JSON.parse(toggleFetch.mock.calls[0][1].body)).toEqual({ expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '1', expanded: true })
    const child = children.querySelector('creative-tree-row')
    child.hasChildren = true
    children.insertAdjacentHTML('beforeend', '<div id="creative-children-2" data-loaded="true"><creative-tree-row creative-id="3"></creative-tree-row></div>')
    controller.syncInitialState(child)
    await flush()
    await controller.saveQueue
    expect(toggleFetch.mock.calls.map(([, options]) => JSON.parse(options.body))).toContainEqual({ expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '2', expanded: true })
    controller.toggleAll({ preventDefault() {} })
    await controller.saveQueue
    expect(row.expanded).toBe(false)
    expect(JSON.parse(toggleFetch.mock.calls.at(-1)[1].body).expanded).toBe(false)
  })

  test('collapse all skips leaf writes in a large loaded tree', async () => {
    children.innerHTML = Array.from({ length: 1000 }, (_, index) =>
      `<creative-tree-row creative-id="${index + 2}"></creative-tree-row>`).join('')
    controller.toggleAll({ preventDefault() {} })
    await flush()
    await controller.saveQueue
    toggleFetch.mockClear()
    controller.toggleAll({ preventDefault() {} })
    await controller.saveQueue
    expect(toggleFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(toggleFetch.mock.calls[0][1].body)).toEqual({ expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '1', expanded: false })
    expect(Array.from(controller.element.querySelectorAll('creative-tree-row')).every((item) => item.expanded === false)).toBe(true)
  })

  test('collapse all still clears a previously expanded row that lost its children', async () => {
    row.hasChildren = false
    row.expanded = true
    controller.allExpanded = true
    controller.toggleAll({ preventDefault() {} })
    await controller.saveQueue
    expect(toggleFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(toggleFetch.mock.calls[0][1].body)).toEqual({ expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '1', expanded: false })
  })

  test('a collapse wins over an unfinished lazy expansion', async () => {
    let finish
    controller.ensureLoaded = () => new Promise((resolve) => { finish = resolve })
    const pending = controller.expandRow(row)
    controller.collapseRow(row)
    finish(true)
    await pending
    await controller.saveQueue
    expect(row.expanded).toBe(false)
    expect(children.style.display).toBe('none')
    expect(toggleFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(toggleFetch.mock.calls[0][1].body).expanded).toBe(false)
  })

  test('save requests are serialized and retain their context', async () => {
    let finish
    toggleFetch.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    controller.saveExpansionState('1', true)
    controller.currentCreativeId = '9'
    controller.saveExpansionState('1', false)
    await flush()
    expect(toggleFetch).toHaveBeenCalledTimes(1)
    finish({ ok: true, headers: new Headers(), json: async () => ({ success: true }) })
    await controller.saveQueue
    expect(toggleFetch.mock.calls.map(([, options]) => JSON.parse(options.body))).toEqual([
      { expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '1', expanded: true },
      { expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: '9', node_id: '1', expanded: false },
    ])
  })
  test('writes from replacement controllers wait for the previous screen queue', async () => {
    let finish
    toggleFetch.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    controller.connect()
    controller.saveExpansionState('1', true)
    controller.saveExpansionState('2', true)
    await flush()
    controller.disconnect()
    const replacement = Object.create(ExpansionController.prototype)
    Object.defineProperty(replacement, 'element', { value: controller.element })
    Object.defineProperty(replacement, 'hasExpandTarget', { value: false })
    replacement.connect()
    replacement.collapseRow(row)
    await flush()
    expect(toggleFetch).toHaveBeenCalledTimes(1)
    finish({ ok: true, headers: new Headers(), json: async () => ({ success: true }) })
    await replacement.saveQueue
    expect(toggleFetch.mock.calls.map(([, options]) => JSON.parse(options.body))).toEqual([
      { expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '1', expanded: true },
      { expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '2', expanded: true },
      { expansion_save_fence: expect.any(Number), expected_user_id: '10', creative_id: null, node_id: '1', expanded: false },
    ])
    replacement.disconnect()
  })

  test('disconnect invalidates an unfinished expansion before reconnecting', async () => {
    controller.connect()
    let finish
    controller.ensureLoaded = () => new Promise((resolve) => { finish = resolve })
    const pending = controller.expandRow(row)
    controller.disconnect()
    controller.connect()
    finish(true)
    await pending
    expect(toggleFetch).not.toHaveBeenCalled()
    expect(row.expanded).toBe(false)
    controller.disconnect()
  })

  test.each(['20', ''])('drops queued writes when the user changes to %s', async (userId) => {
    let finish
    toggleFetch.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    controller.connect()
    controller.saveExpansionState('1', true)
    controller.saveExpansionState('2', true)
    await flush()
    controller.disconnect()
    document.body.dataset.currentUserId = userId
    const oldQueue = controller.saveQueue
    finish({ ok: true, headers: new Headers(), json: async () => ({ success: true }) })
    await oldQueue
    expect(toggleFetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(toggleFetch.mock.calls[0][1].body).expected_user_id).toBe('10')
    controller.connect()
    controller.saveExpansionState('3', false)
    await controller.saveQueue
    expect(toggleFetch).toHaveBeenCalledTimes(userId ? 2 : 1)
    if (userId) expect(JSON.parse(toggleFetch.mock.calls[1][1].body).expected_user_id).toBe(userId)
    controller.disconnect()
  })

  test('a stalled save is aborted and a replacement controller can persist within the timeout', async () => {
    jest.useFakeTimers()
    try {
      toggleFetch.mockImplementationOnce(() => new Promise(() => {}))
      controller.connect()
      controller.saveExpansionState('1', true)
      await jest.advanceTimersByTimeAsync(0)
      const signal = toggleFetch.mock.calls[0][1].signal
      controller.disconnect()
      const replacement = Object.create(ExpansionController.prototype)
      Object.defineProperty(replacement, 'element', { value: controller.element })
      Object.defineProperty(replacement, 'hasExpandTarget', { value: false })
      replacement.connect()
      replacement.collapseRow(row)
      await jest.advanceTimersByTimeAsync(9999)
      expect(toggleFetch).toHaveBeenCalledTimes(1)
      expect(signal.aborted).toBe(false)
      await jest.advanceTimersByTimeAsync(1)
      await replacement.saveQueue
      expect(signal.aborted).toBe(true)
      expect(toggleFetch).toHaveBeenCalledTimes(2)
      const earlier = JSON.parse(toggleFetch.mock.calls[0][1].body)
      const later = JSON.parse(toggleFetch.mock.calls[1][1].body)
      expect(later.expanded).toBe(false)
      expect(later.expansion_save_fence).toBeGreaterThan(earlier.expansion_save_fence)
      expect(jest.getTimerCount()).toBe(0)
      replacement.disconnect()
    } finally {
      jest.useRealTimers()
    }
  })

  test.each(['success', 'failure'])('clears the save timeout after %s', async (outcome) => {
    jest.useFakeTimers()
    try {
      if (outcome === 'failure') toggleFetch.mockRejectedValueOnce(new Error('offline'))
      controller.saveExpansionState('1', true)
      await controller.saveQueue
      const signal = toggleFetch.mock.calls[0][1].signal
      expect(jest.getTimerCount()).toBe(0)
      await jest.advanceTimersByTimeAsync(10000)
      expect(signal.aborted).toBe(false)
    } finally {
      jest.useRealTimers()
    }
  })

  test('a rejected save does not block later writes', async () => {
    toggleFetch.mockRejectedValueOnce(new Error('offline'))
    controller.saveExpansionState('1', true)
    controller.saveExpansionState('1', false)
    await controller.saveQueue
    expect(toggleFetch).toHaveBeenCalledTimes(2)
    expect(JSON.parse(toggleFetch.mock.calls[1][1].body).expanded).toBe(false)
  })

})
