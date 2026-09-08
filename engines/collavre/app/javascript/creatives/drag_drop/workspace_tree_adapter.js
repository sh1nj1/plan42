import { createDragDropRegistry } from '../../lib/dnd/registry'
import { getDragKind, readDragData, writeDragData } from '../../lib/dnd/envelope'
import {
  dispatchDropCompletion,
  emitDropSignal,
  ensureDragWindowId,
} from '../../lib/dnd/session'
import { getVerticalDropPosition } from '../../lib/dnd/hit_test'
import { executeMoveCommand, MOVE_STATUSES } from './move_command'
import { reportPartialMove } from './move_feedback'
import {
  applyWorkspaceMove,
  captureWorkspaceMove,
  findWorkspaceItem,
  hasKnownWorkspaceCycle,
  revertWorkspaceMove,
  showWorkspaceDropPreview,
  workspaceItemFromRow,
} from './workspace_tree_dom'

export const WORKSPACE_TREE_EXPAND_DELAY_MS = 600
const ROW_SELECTOR = '.creative-workspace-tree-row[data-creative-id]'

function creativePayload(item, row) {
  const creativeId = item.dataset.creativeId
  const parentId = item.dataset.parentId || null
  return {
    creativeId,
    treeId: row.id,
    parentId,
    level: Number(item.dataset.level || 1),
    isRoot: !parentId,
    source: 'workspace-tree',
    sourceWindowId: ensureDragWindowId(),
  }
}

function startWorkspaceDrag({ el: row, event }) {
  const item = workspaceItemFromRow(row)
  if (!item || !event.dataTransfer) return

  const payload = creativePayload(item, row)
  writeDragData(event.dataTransfer, {
    kind: 'creative',
    ids: [payload.creativeId],
    payload,
  })
  event.dataTransfer.effectAllowed = 'copyMove'
  row.classList.add('is-dragging')
}

function endWorkspaceDrag({ el: row }) {
  row.classList.remove('is-dragging')
}

function hitWorkspaceRow({ el: row, event }) {
  return getVerticalDropPosition({
    clientY: event.clientY,
    rect: row.getBoundingClientRect(),
    previousPosition: ['up', 'down', 'child']
      .find((position) => row.classList.contains(`drag-over-${position}`)),
  })
}

function previewWorkspaceRow(controller, expandDelay, { el: row, hit }) {
  const item = workspaceItemFromRow(row)
  const clearHighlight = showWorkspaceDropPreview(row, hit)
  let expandTimer = null
  if (hit === 'child' && item?.dataset.hasChildren === 'true' && item.dataset.expanded !== 'true') {
    expandTimer = window.setTimeout(() => {
      expandTimer = null
      controller.expandBranchForDrag(item.dataset.creativeId)
    }, expandDelay)
  }

  return () => {
    if (expandTimer) window.clearTimeout(expandTimer)
    clearHighlight()
  }
}

function completionDetail(ids, payload, targetId, direction) {
  return {
    creativeId: ids[0],
    creativeIds: ids,
    treeId: payload?.treeId || null,
    sourceWindowId: payload?.sourceWindowId || null,
    targetCreativeId: targetId,
    direction,
    context: 'target',
  }
}

function notifyMoveCompletion(ids, payload, targetId, direction, mode) {
  const detail = completionDetail(ids, payload, targetId, direction)
  dispatchDropCompletion(detail)
  // The source window reacts to this signal by removing the row it dragged.
  // A link leaves the original where it is, so only a move may broadcast.
  if (mode === 'move' && detail.sourceWindowId) emitDropSignal(detail)
}

async function performWorkspaceDrop({ root, execute, el: row, event, hit, ids, payload }) {
  const targetItem = workspaceItemFromRow(row)
  if (!targetItem || hasKnownWorkspaceCycle({ root, ids, targetItem, direction: hit })) return

  const mode = event.shiftKey ? 'link' : 'move'
  const sourceItem = ids.length === 1 ? findWorkspaceItem(root, ids[0]) : null
  const snapshot = mode === 'move' && sourceItem ? captureWorkspaceMove(sourceItem) : null
  if (snapshot) applyWorkspaceMove(snapshot, targetItem, hit)

  let result
  try {
    result = await execute({ ids, targetId: targetItem.dataset.creativeId, direction: hit, mode })
  } catch (error) {
    if (snapshot) revertWorkspaceMove(snapshot)
    console.error('Failed to execute workspace tree drop', error)
    return
  }

  if (result.status === MOVE_STATUSES.FAILURE) {
    if (snapshot) revertWorkspaceMove(snapshot)
    return
  }

  reportPartialMove(result)
  notifyMoveCompletion(ids, payload, targetItem.dataset.creativeId, hit, mode)
}

export function createWorkspaceTreeDragDrop({
  root,
  controller,
  execute = executeMoveCommand,
  expandDelay = WORKSPACE_TREE_EXPAND_DELAY_MS,
} = {}) {
  const registry = createDragDropRegistry({
    root,
    getKind: getDragKind,
    readData: readDragData,
    onError: (error) => console.error('Workspace tree drag and drop failed', error),
  })

  registry.registerDragSource({
    selector: ROW_SELECTOR,
    onDragStart: startWorkspaceDrag,
    onDragEnd: endWorkspaceDrag,
  })
  registry.registerDropZone({
    selector: ROW_SELECTOR,
    accepts: 'creative',
    hitTest: hitWorkspaceRow,
    preview: (details) => previewWorkspaceRow(controller, expandDelay, details),
    onDrop: (details) => performWorkspaceDrop({ root, execute, ...details }),
    dropEffect: ({ event }) => event.shiftKey ? 'copy' : 'move',
  })

  return registry
}
