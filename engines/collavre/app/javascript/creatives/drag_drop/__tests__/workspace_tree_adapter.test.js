/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'
import { writeDragData } from '../../../lib/dnd/envelope'
import { resetDragSessionCache } from '../../../lib/dnd/session'
import { createWorkspaceTreeDragDrop } from '../workspace_tree_adapter'

function item(id, { parentId = null, level = 1, hasChildren = false, expanded = false } = {}) {
  const parent = parentId ? ` data-parent-id="${parentId}"` : ''
  return `
    <li class="creative-workspace-tree-item" data-creative-id="${id}" data-level="${level}"
        data-has-children="${hasChildren}" data-expanded="${expanded}"${parent}>
      <div id="workspace-creative-${id}" class="creative-workspace-tree-row"
           data-creative-id="${id}" data-level="${level}"${parent} draggable="true"></div>
    </li>
  `
}

function dataTransfer() {
  const values = new Map()
  return {
    dropEffect: 'none',
    effectAllowed: 'none',
    get types() { return [...values.keys()] },
    getData(type) { return values.get(type) || '' },
    setData(type, value) { values.set(type, String(value)) },
  }
}

function event(type, element, transfer, { clientY = 50, shiftKey = false } = {}) {
  const dragEvent = new Event(type, { bubbles: true, cancelable: true })
  Object.defineProperties(dragEvent, {
    dataTransfer: { value: transfer },
    clientY: { value: clientY },
    shiftKey: { value: shiftKey },
  })
  element.dispatchEvent(dragEvent)
  return dragEvent
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

describe('workspace tree drag and drop adapter', () => {
  let root
  let controller
  let execute
  let registry

  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
    resetDragSessionCache()
    document.body.innerHTML = `
      <nav id="workspace-tree"><ul class="creative-workspace-tree-list">
        ${item('1')}${item('2', { hasChildren: true })}${item('3')}
      </ul></nav>
    `
    root = document.getElementById('workspace-tree')
    root.querySelectorAll('.creative-workspace-tree-row').forEach((row) => {
      row.getBoundingClientRect = () => ({ top: 0, height: 100 })
    })
    controller = { expandBranchForDrag: jest.fn(), revealBranchAfterDrop: jest.fn() }
    execute = jest.fn(async command => ({ status: 'success', succeededIds: command.ids }))
    registry = createWorkspaceTreeDragDrop({ root, controller, execute })
  })

  afterEach(() => {
    registry.destroy()
    jest.useRealTimers()
  })

  test('moves from the left tree to the left tree and emits synchronization', async () => {
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    const transfer = dataTransfer()
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    event('dragover', document.getElementById('workspace-creative-2'), transfer)
    event('drop', document.getElementById('workspace-creative-2'), transfer)
    await flush()

    expect(execute).toHaveBeenCalledWith({ ids: ['1'], targetId: '2', direction: 'child', mode: 'move' })
    expect([...root.querySelector('ul').children].map(entry => entry.dataset.creativeId)).toEqual(['1', '2', '3'])
    expect(completion).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ creativeIds: ['1'], targetCreativeId: '2' }),
    }))
  })

  // The panel only renders expanded branches, so a drop into a collapsed one
  // used to make the row vanish with nothing to say the move had landed.
  test('reveals the destination branch after a child drop', async () => {
    const transfer = dataTransfer()
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    event('dragover', document.getElementById('workspace-creative-2'), transfer)
    event('drop', document.getElementById('workspace-creative-2'), transfer)
    await flush()

    expect(controller.revealBranchAfterDrop).toHaveBeenCalledWith('2')
  })

  test('leaves the expansion alone for a sibling drop', async () => {
    const transfer = dataTransfer()
    const row = document.getElementById('workspace-creative-2')
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    event('dragover', row, transfer, { clientY: 5 })
    event('drop', row, transfer, { clientY: 5 })
    await flush()

    expect(execute).toHaveBeenCalledWith(expect.objectContaining({ direction: 'up' }))
    expect(controller.revealBranchAfterDrop).not.toHaveBeenCalled()
  })

  test('accepts a right-tree envelope and reloads through the completion event', async () => {
    const transfer = dataTransfer()
    writeDragData(transfer, {
      kind: 'creative',
      ids: ['9'],
      payload: { creativeId: '9', treeId: 'creative-9', sourceWindowId: 'right-window' },
    })

    event('dragover', document.getElementById('workspace-creative-3'), transfer, { clientY: 10 })
    event('drop', document.getElementById('workspace-creative-3'), transfer, { clientY: 10 })
    await flush()

    expect(execute).toHaveBeenCalledWith({ ids: ['9'], targetId: '3', direction: 'up', mode: 'move' })
  })

  test('keeps the left-tree placement when the server rejects the move', async () => {
    execute.mockResolvedValue({ status: 'failure' })
    const transfer = dataTransfer()
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    event('dragover', document.getElementById('workspace-creative-3'), transfer)
    event('drop', document.getElementById('workspace-creative-3'), transfer)
    await flush()

    expect([...root.querySelector('ul').children].map((entry) => entry.dataset.creativeId)).toEqual(['1', '2', '3'])
  })

  test('does not send a move into a visibly known descendant', async () => {
    const rootItem = root.querySelector('[data-creative-id="1"]')
    const descendants = document.createElement('ul')
    descendants.className = 'creative-workspace-tree-list'
    descendants.innerHTML = item('4', { parentId: '1', level: 2 })
    rootItem.appendChild(descendants)
    const target = document.getElementById('workspace-creative-4')
    target.getBoundingClientRect = () => ({ top: 0, height: 100 })

    const transfer = dataTransfer()
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    event('dragover', target, transfer)
    event('drop', target, transfer)
    await flush()

    expect(execute).not.toHaveBeenCalled()
  })

  test('expands a collapsed child target after 600ms and cancels when leaving', () => {
    jest.useFakeTimers()
    const target = document.getElementById('workspace-creative-2')
    const transfer = dataTransfer()
    writeDragData(transfer, {
      kind: 'creative', ids: ['9'], payload: { creativeId: '9', treeId: 'creative-9' },
    })

    event('dragover', target, transfer)
    jest.advanceTimersByTime(599)
    expect(controller.expandBranchForDrag).not.toHaveBeenCalled()
    jest.advanceTimersByTime(1)
    expect(controller.expandBranchForDrag).toHaveBeenCalledWith('2')

    controller.expandBranchForDrag.mockClear()
    event('dragover', target, transfer)
    event('dragleave', target, transfer)
    jest.advanceTimersByTime(600)
    expect(controller.expandBranchForDrag).not.toHaveBeenCalled()
  })
  test('keeps placements unchanged while the server request is pending', async () => {
    let finish
    execute.mockImplementation(() => new Promise(resolve => { finish = resolve }))
    const transfer = dataTransfer()
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    event('drop', document.getElementById('workspace-creative-3'), transfer)
    expect([...root.querySelector('ul').children].map(entry => entry.dataset.creativeId)).toEqual(['1', '2', '3'])
    finish({ status: 'failure', succeededIds: [] })
    await flush()
    expect([...root.querySelector('ul').children].map(entry => entry.dataset.creativeId)).toEqual(['1', '2', '3'])
  })

  test('link completion never broadcasts a source move', async () => {
    const transfer = dataTransfer()
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    const setItem = jest.spyOn(Storage.prototype, 'setItem')
    event('drop', document.getElementById('workspace-creative-3'), transfer, { shiftKey: true })
    await flush()
    expect(execute).toHaveBeenCalledWith(expect.objectContaining({ mode: 'link' }))
    expect(setItem.mock.calls.some(([key]) => key === 'collavre.dragDropSignal')).toBe(false)
    setItem.mockRestore()
  })

  test('uses stored hysteresis rather than reading workspace CSS', async () => {
    const transfer = dataTransfer()
    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    const target = document.getElementById('workspace-creative-3')
    event('dragover', target, transfer, { clientY: 1 })
    target.className = 'creative-workspace-tree-row'
    event('dragover', target, transfer, { clientY: 40 })
    event('drop', target, transfer, { clientY: 99 })
    await flush()
    expect(execute).toHaveBeenCalledWith(expect.objectContaining({ direction: 'up' }))
  })

})
