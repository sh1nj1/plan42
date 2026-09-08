// The hit test speaks the move vocabulary ('up' / 'down' / 'child'); the
// stylesheet speaks the presentation one ('top' / 'bottom' / 'child'). Keep the
// translation in one place: building a class name from the direction produced
// `drag-over-up` / `drag-over-down`, which no rule matches and no cleanup
// removes.
const PREVIEW_CLASS_BY_DIRECTION = Object.freeze({
  up: 'drag-over-top',
  down: 'drag-over-bottom',
  child: 'drag-over-child',
})

const PREVIEW_CLASSES = Object.freeze(Object.values(PREVIEW_CLASS_BY_DIRECTION))

export function workspaceItemFromRow(row) {
  return row?.closest?.('.creative-workspace-tree-item') || null
}

export function findWorkspaceItem(root, creativeId) {
  if (!root || creativeId === null || creativeId === undefined) return null
  return [...root.querySelectorAll('.creative-workspace-tree-item[data-creative-id]')]
    .find((item) => item.dataset.creativeId === String(creativeId)) || null
}

export function destinationParentId(targetItem, direction) {
  if (direction === 'child') return targetItem?.dataset.creativeId || null
  return targetItem?.dataset.parentId || null
}

export function hasKnownWorkspaceCycle({ root, ids, targetItem, direction }) {
  const movingIds = new Set(ids.map(String))
  const targetId = targetItem?.dataset.creativeId
  if (!targetId || movingIds.has(String(targetId))) return true

  let parentId = destinationParentId(targetItem, direction)
  const visited = new Set()
  while (parentId && !visited.has(String(parentId))) {
    const normalizedId = String(parentId)
    if (movingIds.has(normalizedId)) return true
    visited.add(normalizedId)
    const parentItem = findWorkspaceItem(root, normalizedId)
    if (!parentItem) return false
    parentId = parentItem.dataset.parentId || null
  }
  return false
}

export function showWorkspaceDropPreview(row, direction) {
  const clear = () => PREVIEW_CLASSES.forEach((className) => row.classList.remove(className))

  clear()
  const className = PREVIEW_CLASS_BY_DIRECTION[direction]
  if (className) row.classList.add(className)
  return clear
}
