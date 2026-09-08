/**
 * @jest-environment jsdom
 */

// The right-hand creative tree moves the row before the server has agreed to
// anything, so every non-success outcome has to put the DOM back. That recovery
// is adapter work — `move_command.js` stays DOM-free — and this file pins the
// seam between the two.
import { jest } from '@jest/globals'
import {
  createMoveContext,
  applyMove,
  runMoveWithDomRecovery,
} from '../operations'
import { createMoveCommand, InvalidMoveCommandError } from '../move_command'

function mountTree() {
  document.body.innerHTML = `
    <div id="creatives">
      <creative-tree-row creative-id="3" parent-id="1" level="2">
        <div class="creative-tree" id="creative-3" data-id="3" data-level="2"></div>
      </creative-tree-row>
      <creative-tree-row creative-id="9" parent-id="1" level="2">
        <div class="creative-tree" id="creative-9" data-id="9" data-level="2"></div>
      </creative-tree-row>
    </div>
  `

  return {
    draggedRow: document.querySelector('creative-tree-row[creative-id="3"]'),
    targetRow: document.querySelector('creative-tree-row[creative-id="9"]'),
  }
}

// Drops row 3 onto row 9 as a child, exactly as the drop handler does, and
// hands back what the adapter needs to undo it.
function optimisticallyDropAsChild() {
  const { draggedRow, targetRow } = mountTree()
  const draggedState = { row: draggedRow, parentId: '1', level: 2, isRoot: false }
  const moveContext = createMoveContext(draggedState, targetRow, null)
  const { newParentId } = applyMove({
    direction: 'child',
    targetRow,
    draggedState,
    draggedChildren: null,
    moveContext,
  })

  return { draggedRow, targetRow, moveContext, newParentId }
}

function childrenContainer() {
  return document.getElementById('creative-children-9')
}

function topLevelRowIds() {
  return Array.from(document.querySelectorAll('#creatives > creative-tree-row'))
    .map((row) => row.getAttribute('creative-id'))
}

const COMMAND = () => createMoveCommand({ ids: ['3'], targetId: '9', direction: 'child' })

afterEach(() => {
  document.body.innerHTML = ''
})

test('an accepted move leaves the optimistic DOM exactly where the drop put it', async () => {
  const { draggedRow, moveContext, newParentId } = optimisticallyDropAsChild()
  const execute = jest.fn().mockResolvedValue({ status: 'success', ok: true })

  const result = await runMoveWithDomRecovery({
    command: COMMAND(),
    moveContext,
    attemptedParentId: newParentId,
    execute,
  })

  expect(result.status).toBe('success')
  expect(childrenContainer().contains(draggedRow)).toBe(true)
  expect(draggedRow.getAttribute('parent-id')).toBe('9')
})

test('a rejected move puts the row back under its original parent', async () => {
  const { draggedRow, moveContext, newParentId } = optimisticallyDropAsChild()
  const execute = jest.fn().mockResolvedValue({ status: 'failure', ok: false })

  await runMoveWithDomRecovery({
    command: COMMAND(),
    moveContext,
    attemptedParentId: newParentId,
    execute,
  })

  expect(topLevelRowIds()).toEqual(['3', '9'])
  expect(draggedRow.getAttribute('parent-id')).toBe('1')
  expect(draggedRow.getAttribute('level')).toBe('2')
  // ensureChildrenContainer created it for the optimistic drop; the undo takes
  // it away again so row 9 does not keep a phantom expand arrow.
  expect(childrenContainer()).toBeNull()
  expect(document.querySelector('creative-tree-row[creative-id="9"]').hasAttribute('has-children'))
    .toBe(false)
})

test('a transport failure recovers the DOM just like a rejection', async () => {
  const { draggedRow, moveContext, newParentId } = optimisticallyDropAsChild()
  const execute = jest.fn().mockResolvedValue({
    status: 'failure',
    ok: false,
    failures: [{ id: '3', reason: 'network_error' }],
  })

  await runMoveWithDomRecovery({
    command: COMMAND(),
    moveContext,
    attemptedParentId: newParentId,
    execute,
  })

  expect(topLevelRowIds()).toEqual(['3', '9'])
  expect(draggedRow.getAttribute('parent-id')).toBe('1')
})

test('a partial result recovers the DOM — half a move is not a move', async () => {
  const { draggedRow, moveContext, newParentId } = optimisticallyDropAsChild()
  const execute = jest.fn().mockResolvedValue({ status: 'partial', ok: false })

  await runMoveWithDomRecovery({
    command: COMMAND(),
    moveContext,
    attemptedParentId: newParentId,
    execute,
  })

  expect(topLevelRowIds()).toEqual(['3', '9'])
  expect(draggedRow.getAttribute('parent-id')).toBe('1')
})

test('a failure without an optimistic context is reported without touching the DOM', async () => {
  mountTree()
  const execute = jest.fn().mockResolvedValue({ status: 'partial', ok: false })

  const result = await runMoveWithDomRecovery({
    command: createMoveCommand({ ids: ['3'], targetId: '9', direction: 'child', mode: 'link' }),
    execute,
  })

  expect(result.status).toBe('partial')
  expect(topLevelRowIds()).toEqual(['3', '9'])
})

test('an invalid command recovers the DOM and surfaces the error', async () => {
  const { draggedRow, moveContext, newParentId } = optimisticallyDropAsChild()

  await expect(runMoveWithDomRecovery({
    command: { ids: [], targetId: '9', direction: 'child' },
    moveContext,
    attemptedParentId: newParentId,
  })).rejects.toThrow(InvalidMoveCommandError)

  expect(topLevelRowIds()).toEqual(['3', '9'])
  expect(draggedRow.getAttribute('parent-id')).toBe('1')
})

test('the command reaches the server through the injected api', async () => {
  const { moveContext, newParentId } = optimisticallyDropAsChild()
  const sendNewOrder = jest.fn().mockResolvedValue({ ok: true, status: 200 })

  const result = await runMoveWithDomRecovery({
    command: COMMAND(),
    moveContext,
    attemptedParentId: newParentId,
    api: { sendNewOrder },
  })

  expect(sendNewOrder).toHaveBeenCalledWith({ draggedId: '3', targetId: '9', direction: 'child' })
  expect(result.status).toBe('success')
})

test('the real reorder path reverts the DOM on a 403', async () => {
  const { draggedRow, moveContext, newParentId } = optimisticallyDropAsChild()
  const sendNewOrder = jest.fn().mockResolvedValue({ ok: false, status: 403 })

  const result = await runMoveWithDomRecovery({
    command: COMMAND(),
    moveContext,
    attemptedParentId: newParentId,
    api: { sendNewOrder },
  })

  expect(result.failures[0].reason).toBe('permission_denied')
  expect(topLevelRowIds()).toEqual(['3', '9'])
  expect(draggedRow.getAttribute('parent-id')).toBe('1')
})

test('a command runner that throws synchronously still triggers recovery', async () => {
  const { draggedRow, moveContext, newParentId } = optimisticallyDropAsChild()
  const execute = jest.fn(() => { throw new Error('boom') })

  await expect(runMoveWithDomRecovery({
    command: COMMAND(),
    moveContext,
    attemptedParentId: newParentId,
    execute,
  })).rejects.toThrow('boom')

  expect(topLevelRowIds()).toEqual(['3', '9'])
  expect(draggedRow.getAttribute('parent-id')).toBe('1')
})
