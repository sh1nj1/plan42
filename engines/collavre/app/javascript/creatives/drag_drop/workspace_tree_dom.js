const PREVIEW_CLASSES = ['drag-over-top', 'drag-over-bottom', 'drag-over-child']

export function workspaceItemFromRow(row) {
  return row?.closest?.('.creative-workspace-tree-item') || null
}

export function findWorkspaceItem(root, creativeId) {
  return [...root.querySelectorAll('.creative-workspace-tree-item[data-creative-id]')]
    .find((item) => item.dataset.creativeId === String(creativeId)) || null
}

// Only reached once `hasKnownWorkspaceCycle` has proven the target names a
// creative, so the item and its id are both there.
function destinationParentId(targetItem, direction) {
  if (direction === 'child') return targetItem.dataset.creativeId
  return targetItem.dataset.parentId || null
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
  PREVIEW_CLASSES.forEach((className) => row.classList.remove(className))
  row.classList.add(`drag-over-${direction}`)
  return () => PREVIEW_CLASSES.forEach((className) => row.classList.remove(className))
}
