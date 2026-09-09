/** @jest-environment jsdom */
import { jest } from '@jest/globals'

const sendNewOrder = jest.fn()
jest.unstable_mockModule('../../../lib/api/drag_drop', () => ({
  sendNewOrder,
  sendLinkedCreative: jest.fn(),
  sendTopicMove: jest.fn(),
  isAuthenticationRedirect: () => false,
}))
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog: jest.fn() }))
const { createCreativeTreeDragDrop } = await import('../event_handlers')
const { createWorkspaceTreeDragDrop } = await import('../workspace_tree_adapter')
const { resetDragSessionCache } = await import('../../../lib/dnd/session')
const { getDraggedState, resetDraggedState } = await import('../state')

let right, left, execute, pointTarget
const row = id => document.getElementById(id)
const point = el => ({ clientX: 50, clientY: el.getBoundingClientRect().top + 50, target: el })
function touch(type, source, target = source) {
  pointTarget = target
  source.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true,
    touches: type === 'touchend' ? [] : [point(target)],
    changedTouches: [point(target)],
  }))
}

beforeEach(() => {
  jest.useFakeTimers()
  jest.spyOn(console, 'error').mockImplementation(() => {})
  sendNewOrder.mockReset().mockResolvedValue({ ok: false, status: 403 })
  localStorage.clear()
  sessionStorage.clear()
  resetDragSessionCache()
  document.body.innerHTML = '<div id="creatives">' + ['1', '9'].map(id => `
    <creative-tree-row creative-id="${id}" level="1">
      <div class="creative-tree" id="creative-${id}" draggable="true"></div>
    </creative-tree-row>`).join('') + '</div><nav><ul>' + ['2', '3'].map(id => `
    <li class="creative-workspace-tree-item" data-creative-id="${id}" data-level="1">
      <div id="workspace-${id}" class="creative-workspace-tree-row" data-creative-id="${id}" draggable="true"></div>
    </li>`).join('') + '</ul></nav>'
  document.querySelectorAll('[draggable]').forEach((el, index) => {
    el.getBoundingClientRect = () => ({ left: 0, right: 100, top: index * 100,
      bottom: index * 100 + 100, width: 100, height: 100 })
  })
  document.elementFromPoint = () => pointTarget
  execute = jest.fn(async command => ({ status: 'success', succeededIds: command.ids }))
  right = createCreativeTreeDragDrop()
  left = createWorkspaceTreeDragDrop({ root: document.querySelector('nav'),
    controller: { expandBranchForDrag: jest.fn() }, execute })
})

afterEach(() => {
  right.destroy()
  left.destroy()
  resetDraggedState()
  resetDragSessionCache()
  document.body.innerHTML = ''
  delete document.elementFromPoint
  jest.restoreAllMocks()
  jest.useRealTimers()
})

test.each([
  ['creative-1', 'workspace-2', '1', '2'],
  ['workspace-2', 'workspace-3', '2', '3'],
])('touch %s → %s invokes the shared move exactly once', async (sourceId, targetId, id, target) => {
  const source = row(sourceId)
  touch('touchstart', source)
  jest.advanceTimersByTime(400)
  touch('touchmove', source, row(targetId))
  touch('touchend', source, row(targetId))
  await Promise.resolve()
  expect(execute).toHaveBeenCalledTimes(1)
  expect(execute).toHaveBeenCalledWith({ ids: [id], targetId: target, direction: 'child', mode: 'move' })
  expect(getDraggedState()).toBeNull()
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
})

test.each(['workspace-2', 'creative-1'])('touch %s → right tree keeps command and failure recovery', async sourceId => {
  const source = row(sourceId)
  touch('touchstart', source)
  jest.advanceTimersByTime(400)
  touch('touchmove', source, row('creative-9'))
  touch('touchend', source, row('creative-9'))
  for (let i = 0; i < 10; i += 1) await Promise.resolve()
  expect(sendNewOrder).toHaveBeenCalledTimes(1)
  expect(sendNewOrder).toHaveBeenCalledWith({ draggedId: sourceId === 'workspace-2' ? '2' : '1',
    targetId: '9', direction: 'child' })
  expect(row('creative-1').closest('creative-tree-row').parentElement.id).toBe('creatives')
  expect(getDraggedState()).toBeNull()
  expect(document.querySelector('.drag-over')).toBeNull()
})

function native(type, source, transfer, target = source) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.defineProperties(event, {
    dataTransfer: { value: transfer },
    clientX: { value: point(target).clientX },
    clientY: { value: point(target).clientY },
  })
  target.dispatchEvent(event)
  return event
}

function emptyTransfer() {
  return { types: [], getData: () => '', setData: jest.fn(), effectAllowed: 'none' }
}

function blockStorage() {
  jest.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('Storage blocked') })
  jest.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('Storage blocked') })
}

test.each(['native', 'touch'])('%s preserves all local tree routes when storage is blocked', async mode => {
  blockStorage()
  for (const [sourceId, targetId, id] of [
    ['workspace-2', 'workspace-3', '2'],
    ['workspace-2', 'creative-9', '2'],
    ['creative-1', 'workspace-3', '1'],
  ]) {
    const source = row(sourceId)
    const target = row(targetId)
    const transfer = emptyTransfer()
    execute.mockClear()
    sendNewOrder.mockClear()
    if (mode === 'native') {
      native('dragstart', source, transfer)
      expect(native('dragover', source, transfer, target).defaultPrevented).toBe(true)
      native('drop', source, transfer, target)
    } else {
      touch('touchstart', source)
      jest.advanceTimersByTime(400)
      touch('touchmove', source, target)
      touch('touchend', source, target)
    }
    for (let i = 0; i < 10; i += 1) await Promise.resolve()
    if (targetId === 'creative-9') {
      expect(sendNewOrder).toHaveBeenCalledWith({ draggedId: id, targetId: '9', direction: 'child' })
    } else {
      expect(execute).toHaveBeenCalledWith({ ids: [id], targetId: '3', direction: 'child', mode: 'move' })
    }
    execute.mockClear()
    sendNewOrder.mockClear()
    native('drop', source, emptyTransfer(), target)
    expect(execute).not.toHaveBeenCalled()
    expect(sendNewOrder).not.toHaveBeenCalled()
    expect(document.querySelector('.is-dragging')).toBeNull()
  }
})

test.each(['dragend', 'escape', 'destroy'])('%s clears the workspace gesture fallback', action => {
  blockStorage()
  const source = row('workspace-2')
  const transfer = emptyTransfer()
  native('dragstart', source, transfer)
  if (action === 'dragend') native('dragend', source, transfer)
  if (action === 'escape') document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
  if (action === 'destroy') left.destroy()
  native('drop', source, transfer, row('creative-9'))
  expect(sendNewOrder).not.toHaveBeenCalled()
  expect(document.querySelector('.is-dragging')).toBeNull()
})

test('local fallback cannot authorize a rejected foreign transfer', () => {
  blockStorage()
  const source = row('workspace-2')
  native('dragstart', source, emptyTransfer())
  const foreign = { types: ['application/x-collavre-creative'], getData: () => JSON.stringify({
    creativeId: '99', treeId: 'foreign-99', token: 'foreign', sourceWindowId: 'foreign',
  }) }
  native('drop', source, foreign, row('creative-9'))
  expect(sendNewOrder).not.toHaveBeenCalled()
  expect(execute).not.toHaveBeenCalled()
})

test('touch cancellation clears the workspace fallback before another drop', () => {
  blockStorage()
  const source = row('workspace-2')
  touch('touchstart', source)
  jest.advanceTimersByTime(400)
  touch('touchmove', source, row('workspace-3'))
  touch('touchcancel', source)
  native('drop', source, emptyTransfer(), row('creative-9'))
  expect(sendNewOrder).not.toHaveBeenCalled()
  expect(execute).not.toHaveBeenCalled()
  expect(document.querySelector('.touch-drag-proxy')).toBeNull()
  expect(document.querySelector('.is-dragging')).toBeNull()
})
