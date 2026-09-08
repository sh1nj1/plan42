import { createDragDropRegistry } from '../../lib/dnd/registry'
import { getDragKind, readDragData, writeDragData } from '../../lib/dnd/envelope'
import {
  dispatchDropCompletion,
  emitDropSignal,
  ensureDragWindowId,
} from '../../lib/dnd/session'
import { getVerticalDropPosition } from '../../lib/dnd/hit_test'
import { executeMoveCommand, MOVE_STATUSES } from './move_command'
import {
  hasKnownWorkspaceCycle,
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

function hitWorkspaceRow({ el: row, event, previousHit }) {
  return getVerticalDropPosition({
    clientY: event.clientY,
    rect: row.getBoundingClientRect(),
    previousPosition: previousHit,
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
  if (mode === 'move' && detail.sourceWindowId) emitDropSignal(detail)
}

async function performWorkspaceDrop({ root, execute, el: row, event, hit, ids, payload }) {
  const targetItem = workspaceItemFromRow(row)
  if (!targetItem || hasKnownWorkspaceCycle({ root, ids, targetItem, direction: hit })) return

  const mode = event.shiftKey ? 'link' : 'move'

  let result
  try {
    result = await execute({ ids, targetId: targetItem.dataset.creativeId, direction: hit, mode })
  } catch (error) {
    console.error('Failed to execute workspace tree drop', error)
    return
  }

  if (result.status === MOVE_STATUSES.FAILURE) {
    return
  }

  if (result.succeededIds.length > 0) {
    notifyMoveCompletion(result.succeededIds, payload, targetItem.dataset.creativeId, hit, mode)
  }
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
