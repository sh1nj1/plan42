/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import ExpansionController from '../creatives/expansion_controller'

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('creative expansion persistence', () => {
  let controller
  let row
  let children
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
    global.fetch = jest.fn().mockResolvedValue({ ok: true, headers: new Headers() })
  })

  test('expand all persists branches including asynchronously inserted descendants', async () => {
    controller.toggleAll({ preventDefault() {} })
    await flush()
    await controller.saveQueue
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ expected_user_id: '10', creative_id: null, node_id: '1', expanded: true })
    const child = children.querySelector('creative-tree-row')
    child.hasChildren = true
    children.insertAdjacentHTML('beforeend', '<div id="creative-children-2" data-loaded="true"><creative-tree-row creative-id="3"></creative-tree-row></div>')
    controller.syncInitialState(child)
    await flush()
    await controller.saveQueue
    expect(fetch.mock.calls.map(([, options]) => JSON.parse(options.body))).toContainEqual({ expected_user_id: '10', creative_id: null, node_id: '2', expanded: true })
    controller.toggleAll({ preventDefault() {} })
    await controller.saveQueue
    expect(row.expanded).toBe(false)
    expect(JSON.parse(fetch.mock.calls.at(-1)[1].body).expanded).toBe(false)
  })

  test('collapse all skips leaf writes in a large loaded tree', async () => {
    children.innerHTML = Array.from({ length: 1000 }, (_, index) =>
      `<creative-tree-row creative-id="${index + 2}"></creative-tree-row>`).join('')
    controller.toggleAll({ preventDefault() {} })
    await flush()
    await controller.saveQueue
    fetch.mockClear()
    controller.toggleAll({ preventDefault() {} })
    await controller.saveQueue
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ expected_user_id: '10', creative_id: null, node_id: '1', expanded: false })
    expect(Array.from(controller.element.querySelectorAll('creative-tree-row')).every((item) => item.expanded === false)).toBe(true)
  })

  test('collapse all still clears a previously expanded row that lost its children', async () => {
    row.hasChildren = false
    row.expanded = true
    controller.allExpanded = true
    controller.toggleAll({ preventDefault() {} })
    await controller.saveQueue
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ expected_user_id: '10', creative_id: null, node_id: '1', expanded: false })
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
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(fetch.mock.calls[0][1].body).expanded).toBe(false)
  })

  test('save requests are serialized and retain their context', async () => {
    let finish
    fetch.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    controller.saveExpansionState('1', true)
    controller.currentCreativeId = '9'
    controller.saveExpansionState('1', false)
    await flush()
    expect(fetch).toHaveBeenCalledTimes(1)
    finish({ headers: new Headers() })
    await controller.saveQueue
    expect(fetch.mock.calls.map(([, options]) => JSON.parse(options.body))).toEqual([
      { expected_user_id: '10', creative_id: null, node_id: '1', expanded: true },
      { expected_user_id: '10', creative_id: '9', node_id: '1', expanded: false },
    ])
  })
  test('writes from replacement controllers wait for the previous screen queue', async () => {
    let finish
    fetch.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
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
    expect(fetch).toHaveBeenCalledTimes(1)
    finish({ headers: new Headers() })
    await replacement.saveQueue
    expect(fetch.mock.calls.map(([, options]) => JSON.parse(options.body))).toEqual([
      { expected_user_id: '10', creative_id: null, node_id: '1', expanded: true },
      { expected_user_id: '10', creative_id: null, node_id: '2', expanded: true },
      { expected_user_id: '10', creative_id: null, node_id: '1', expanded: false },
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
    expect(fetch).not.toHaveBeenCalled()
    expect(row.expanded).toBe(false)
    controller.disconnect()
  })

  test.each(['20', ''])('drops queued writes when the user changes to %s', async (userId) => {
    let finish
    fetch.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve }))
    controller.connect()
    controller.saveExpansionState('1', true)
    controller.saveExpansionState('2', true)
    await flush()
    controller.disconnect()
    document.body.dataset.currentUserId = userId
    const oldQueue = controller.saveQueue
    finish({ headers: new Headers() })
    await oldQueue
    expect(fetch).toHaveBeenCalledTimes(1)
    expect(JSON.parse(fetch.mock.calls[0][1].body).expected_user_id).toBe('10')
    controller.connect()
    controller.saveExpansionState('3', false)
    await controller.saveQueue
    expect(fetch).toHaveBeenCalledTimes(userId ? 2 : 1)
    if (userId) expect(JSON.parse(fetch.mock.calls[1][1].body).expected_user_id).toBe(userId)
    controller.disconnect()
  })

  test('a rejected save does not block later writes', async () => {
    fetch.mockRejectedValueOnce(new Error('offline'))
    controller.saveExpansionState('1', true)
    controller.saveExpansionState('1', false)
    await controller.saveQueue
    expect(fetch).toHaveBeenCalledTimes(2)
    expect(JSON.parse(fetch.mock.calls[1][1].body).expanded).toBe(false)
  })

})
