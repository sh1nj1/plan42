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
