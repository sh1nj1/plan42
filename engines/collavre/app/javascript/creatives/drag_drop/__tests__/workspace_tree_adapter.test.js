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
    controller = { expandBranchForDrag: jest.fn(), cancelDragExpansion: jest.fn() }
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

  test('ignores a drag that starts on a row outside the tree structure', () => {
    const orphan = document.createElement('div')
    orphan.className = 'creative-workspace-tree-row'
    orphan.dataset.creativeId = '99'
    orphan.draggable = true
    root.appendChild(orphan)
    const transfer = dataTransfer()

    event('dragstart', orphan, transfer)

    expect(transfer.types).toEqual([])
    expect(orphan.classList.contains('is-dragging')).toBe(false)
  })

  test('clears the dragging marker when the drag ends', () => {
    const source = document.getElementById('workspace-creative-1')
    const transfer = dataTransfer()

    event('dragstart', source, transfer)
    expect(source.classList.contains('is-dragging')).toBe(true)

    event('dragend', source, transfer)
    expect(source.classList.contains('is-dragging')).toBe(false)
  })

  test('links a multi-selection with shift instead of moving it optimistically', async () => {
    const transfer = dataTransfer()
    writeDragData(transfer, {
      kind: 'creative', ids: ['8', '9'], payload: { creativeId: '8', treeId: 'creative-8' },
    })
    const target = document.getElementById('workspace-creative-2')

    const over = event('dragover', target, transfer, { shiftKey: true })
    event('drop', target, transfer, { shiftKey: true })
    await flush()

    expect(over.dataTransfer.dropEffect).toBe('copy')
    expect(execute).toHaveBeenCalledWith({ ids: ['8', '9'], targetId: '2', direction: 'child', mode: 'link' })
    expect(document.querySelector('[data-creative-id="2"] > ul')).toBeNull()
  })

  test('restores an optimistic move and reports when the request itself fails', async () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    execute.mockRejectedValue(new Error('network down'))
    const transfer = dataTransfer()

    event('dragstart', document.getElementById('workspace-creative-1'), transfer)
    event('dragover', document.getElementById('workspace-creative-3'), transfer)
    event('drop', document.getElementById('workspace-creative-3'), transfer)
    await flush()

    expect([...root.querySelector('ul').children].map((entry) => entry.dataset.creativeId)).toEqual(['1', '2', '3'])
    expect(consoleError).toHaveBeenCalledWith(
      'Failed to execute workspace tree drop',
      expect.objectContaining({ message: 'network down' })
    )
    consoleError.mockRestore()
  })

  test('reports a registry failure without leaving a stale preview', () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    const target = document.getElementById('workspace-creative-3')
    target.getBoundingClientRect = () => { throw new Error('layout unavailable') }
    const transfer = dataTransfer()
    writeDragData(transfer, {
      kind: 'creative', ids: ['9'], payload: { creativeId: '9', treeId: 'creative-9' },
    })

    const over = event('dragover', target, transfer)

    expect(over.defaultPrevented).toBe(false)
    expect(consoleError).toHaveBeenCalledWith(
      'Workspace tree drag and drop failed',
      expect.objectContaining({ message: 'layout unavailable' })
    )
    consoleError.mockRestore()
  })

  test('carries a defaulted level and a payload-less envelope through a drop', async () => {
    const bare = document.createElement('li')
    bare.className = 'creative-workspace-tree-item'
    bare.dataset.creativeId = '5'
    bare.innerHTML = `
      <div id="workspace-creative-5" class="creative-workspace-tree-row"
           data-creative-id="5" draggable="true"></div>
    `
    root.querySelector('ul').appendChild(bare)
    const source = document.getElementById('workspace-creative-5')
    source.getBoundingClientRect = () => ({ top: 0, height: 100 })

    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    const transfer = dataTransfer()
    event('dragstart', source, transfer)
    const target = document.getElementById('workspace-creative-1')
    event('dragover', target, transfer, { clientY: 90 })
    event('drop', target, transfer, { clientY: 90 })
    await flush()

    expect(execute).toHaveBeenCalledWith({ ids: ['5'], targetId: '1', direction: 'down', mode: 'move' })
    expect(completion).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ treeId: 'workspace-creative-5', sourceWindowId: expect.any(String) }),
    }))
  })

  test('falls back to the document root and the shared defaults', () => {
    const defaulted = createWorkspaceTreeDragDrop()
    try {
      expect(typeof defaulted.destroy).toBe('function')
    } finally {
      defaulted.destroy()
    }
  })

  test('reports a failed cross-tree drop that had nothing to roll back', async () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    execute.mockRejectedValue(new Error('server down'))
    const transfer = dataTransfer()
    writeDragData(transfer, {
      kind: 'creative', ids: ['8', '9'], payload: { creativeId: '8', treeId: 'creative-8' },
    })
    const target = document.getElementById('workspace-creative-2')

    event('dragover', target, transfer)
    event('drop', target, transfer)
    await flush()

    expect([...root.querySelector('ul').children].map((entry) => entry.dataset.creativeId)).toEqual(['1', '2', '3'])
    expect(consoleError).toHaveBeenCalledWith(
      'Failed to execute workspace tree drop',
      expect.objectContaining({ message: 'server down' })
    )
    consoleError.mockRestore()
  })

  test('leaves the tree untouched when a cross-tree move is rejected', async () => {
    execute.mockResolvedValue({ status: 'failure' })
    const transfer = dataTransfer()
    writeDragData(transfer, {
      kind: 'creative', ids: ['8', '9'], payload: { creativeId: '8', treeId: 'creative-8' },
    })
    const target = document.getElementById('workspace-creative-2')

    event('dragover', target, transfer)
    event('drop', target, transfer)
    await flush()

    expect([...root.querySelector('ul').children].map((entry) => entry.dataset.creativeId)).toEqual(['1', '2', '3'])
  })

  // A creative envelope has to name the tree it came from: the completion event
  // is how the originating view learns to re-render, and an unnamed source
  // leaves nobody to tell. The shared reader declines it before the zone runs.
  test('declines an envelope that never names its originating tree', async () => {
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    const transfer = dataTransfer()
    writeDragData(transfer, { kind: 'creative', ids: ['9'], payload: { creativeId: '9' } })
    const target = document.getElementById('workspace-creative-2')

    event('dragover', target, transfer)
    event('drop', target, transfer)
    await flush()

    expect(execute).not.toHaveBeenCalled()
    expect(completion).not.toHaveBeenCalled()
  })

  // A tab still running the pre-envelope build writes only the legacy payload and
  // never names its window, so there is nobody to signal back to.
  test('completes a legacy drop that names no originating window', async () => {
    window.localStorage.setItem('collavre.dragToken', 'token-under-test')
    resetDragSessionCache()
    const completion = jest.fn()
    window.addEventListener('collavre:creative-drop-complete', completion, { once: true })
    const transfer = dataTransfer()
    transfer.setData('application/x-collavre-creative', JSON.stringify({
      creativeId: '9',
      treeId: 'creative-9',
      token: 'token-under-test',
      selectedCreativeIds: [],
    }))
    const target = document.getElementById('workspace-creative-2')

    event('dragover', target, transfer)
    event('drop', target, transfer)
    await flush()

    expect(completion).toHaveBeenCalledWith(expect.objectContaining({
      detail: expect.objectContaining({ sourceWindowId: null }),
    }))
    expect(window.localStorage.getItem('collavre.dragDropSignal')).toBeNull()
  })

  // The source window reacts to this signal by deleting the row it dragged, so
  // broadcasting a link would destroy the original the link was made from.
  test('signals the source window for a cross-window move but never for a link', async () => {
    const setItem = jest.spyOn(Storage.prototype, 'setItem')
    const target = document.getElementById('workspace-creative-2')
    const envelope = () => {
      const transfer = dataTransfer()
      writeDragData(transfer, {
        kind: 'creative',
        ids: ['9'],
        payload: { creativeId: '9', treeId: 'creative-9', sourceWindowId: 'right-window' },
      })
      return transfer
    }

    const linked = envelope()
    event('dragover', target, linked, { shiftKey: true })
    event('drop', target, linked, { shiftKey: true })
    await flush()
    expect(setItem).not.toHaveBeenCalledWith('collavre.dragDropSignal', expect.any(String))

    const moved = envelope()
    event('dragover', target, moved)
    event('drop', target, moved)
    await flush()
    expect(setItem).toHaveBeenCalledWith('collavre.dragDropSignal', expect.any(String))

    setItem.mockRestore()
  })

  // The dialog copy comes from the server and is covered by move_feedback's own
  // suite; here only the hand-off from the adapter matters.
  test('surfaces the rows a partial move left behind', async () => {
    const consoleError = jest.spyOn(console, 'error').mockImplementation(() => {})
    execute.mockResolvedValue({
      status: 'partial',
      succeededIds: ['8'],
      failedIds: ['9'],
      failures: [{ id: '9', reason: 'network_error', message: '' }],
    })
    const transfer = dataTransfer()
    writeDragData(transfer, {
      kind: 'creative', ids: ['8', '9'], payload: { creativeId: '8', treeId: 'creative-8' },
    })
    const target = document.getElementById('workspace-creative-2')

    event('dragover', target, transfer)
    event('drop', target, transfer)
    await flush()

    expect(consoleError).toHaveBeenCalledWith(
      'Creative move partially failed',
      expect.objectContaining({ failedIds: ['9'] })
    )
    consoleError.mockRestore()
  })

  test('expands after 600ms and invalidates the request on leave, drop, and dragend', () => {
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
    expect(controller.cancelDragExpansion).toHaveBeenCalledTimes(1)

    event('dragover', target, transfer)
    event('drop', target, transfer)
    expect(controller.cancelDragExpansion).toHaveBeenCalledTimes(2)

    event('dragover', target, transfer)
    event('dragend', target, transfer)
    expect(controller.cancelDragExpansion).toHaveBeenCalledTimes(3)
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
