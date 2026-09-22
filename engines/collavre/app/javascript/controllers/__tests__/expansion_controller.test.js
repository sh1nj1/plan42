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
    expect(JSON.parse(fetch.mock.calls[0][1].body)).toEqual({ creative_id: null, node_id: '1', expanded: true })
    const child = children.querySelector('creative-tree-row')
    child.hasChildren = true
    children.insertAdjacentHTML('beforeend', '<div id="creative-children-2" data-loaded="true"><creative-tree-row creative-id="3"></creative-tree-row></div>')
    controller.syncInitialState(child)
    await flush()
    await controller.saveQueue
    expect(fetch.mock.calls.map(([, options]) => JSON.parse(options.body))).toContainEqual({ creative_id: null, node_id: '2', expanded: true })
    controller.toggleAll({ preventDefault() {} })
    await controller.saveQueue
    expect(row.expanded).toBe(false)
    expect(JSON.parse(fetch.mock.calls.at(-1)[1].body).expanded).toBe(false)
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
      { creative_id: null, node_id: '1', expanded: true },
      { creative_id: '9', node_id: '1', expanded: false },
    ])
  })
})
