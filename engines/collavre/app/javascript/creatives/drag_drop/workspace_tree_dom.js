const PREVIEW_CLASSES = ['drag-over-top', 'drag-over-bottom', 'drag-over-child']

export function workspaceItemFromRow(row) {
  return row?.closest?.('.creative-workspace-tree-item') || null
}

export function findWorkspaceItem(root, creativeId) {
  if (!root || creativeId === null || creativeId === undefined) return null
  return [...root.querySelectorAll('.creative-workspace-tree-item[data-creative-id]')]
    .find((item) => item.dataset.creativeId === String(creativeId)) || null
}

function childList(item) {
  return [...(item?.children || [])]
    .find((child) => child.matches?.('.creative-workspace-tree-list')) || null
}

function directChildItems(item) {
  return [...(childList(item)?.children || [])]
    .filter((child) => child.matches?.('.creative-workspace-tree-item'))
}

function setItemLevel(item, level) {
  item.dataset.level = String(level)
  const row = item.querySelector(':scope > .creative-workspace-tree-row')
  if (row) row.dataset.level = String(level)
  directChildItems(item).forEach((child) => setItemLevel(child, level + 1))
}

function setItemParent(item, parentId) {
  const row = item.querySelector(':scope > .creative-workspace-tree-row')
  if (parentId) {
    item.dataset.parentId = String(parentId)
    if (row) row.dataset.parentId = String(parentId)
  } else {
    delete item.dataset.parentId
    if (row) delete row.dataset.parentId
  }
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

export function captureWorkspaceMove(item) {
  return {
    item,
    parentList: item.parentNode,
    nextSibling: item.nextSibling,
    parentId: item.dataset.parentId || null,
    level: Number(item.dataset.level || 1),
    createdChildList: null,
  }
}

function ensureChildList(item, snapshot) {
  const existing = childList(item)
  if (existing) return existing

  const list = document.createElement('ul')
  list.className = 'creative-workspace-tree-list'
  item.appendChild(list)
  snapshot.createdChildList = list
  return list
}

export function applyWorkspaceMove(snapshot, targetItem, direction) {
  const { item } = snapshot
  let parentId
  let level

  if (direction === 'child') {
    parentId = targetItem.dataset.creativeId
    level = Number(targetItem.dataset.level || 1) + 1
    ensureChildList(targetItem, snapshot).appendChild(item)
  } else {
    parentId = targetItem.dataset.parentId || null
    level = Number(targetItem.dataset.level || 1)
    const targetList = targetItem.parentNode
    const reference = direction === 'up' ? targetItem : targetItem.nextSibling
    targetList.insertBefore(item, reference)
  }

  setItemParent(item, parentId)
  setItemLevel(item, level)
  return parentId
}

export function revertWorkspaceMove(snapshot) {
  const { item, parentList, nextSibling, parentId, level, createdChildList } = snapshot
  parentList.insertBefore(item, nextSibling)
  setItemParent(item, parentId)
  setItemLevel(item, level)
  if (createdChildList && createdChildList.childElementCount === 0) createdChildList.remove()
}

export function showWorkspaceDropPreview(row, direction) {
  PREVIEW_CLASSES.forEach((className) => row.classList.remove(className))
  row.classList.add(`drag-over-${direction}`)
  return () => PREVIEW_CLASSES.forEach((className) => row.classList.remove(className))
}
