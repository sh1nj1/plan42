export const DRAGGABLE_SELECTOR = '.creative-tree';

export function clearDragHighlight(tree) {
  if (!tree) return;
  tree.classList.remove(
    'drag-over',
    'drag-over-top',
    'drag-over-bottom',
    'drag-over-child',
    'child-drop-indicator-active'
  );
}

export function asTreeRow(node) {
  return node ? node.closest('creative-tree-row') : null;
}

export function getChildrenContainer(row) {
  if (!row) return null;
  const creativeId = row.getAttribute('creative-id');
  if (!creativeId) return null;
  return document.getElementById(`creative-children-${creativeId}`);
}

export function ensureChildrenContainer(row) {
  if (!row) return null;
  const creativeId = row.getAttribute('creative-id');
  if (!creativeId) return null;
  let container = document.getElementById(`creative-children-${creativeId}`);
  if (!container) {
    container = document.createElement('div');
    container.className = 'creative-children';
    container.id = `creative-children-${creativeId}`;
    container.dataset.loaded = 'true';
    container.dataset.expanded = 'true';
    container.style.display = '';
    row.parentNode?.insertBefore(container, row.nextSibling);
  }
  return container;
}

function getNodeAfterBlock(row) {
  if (!row) return null;
  const children = getChildrenContainer(row);
  let node = children ? children.nextSibling : row.nextSibling;
  while (node && node.nodeType === Node.TEXT_NODE) {
    node = node.nextSibling;
  }
  return node;
}

export function moveBlockBefore(draggedRow, draggedChildren, referenceRow) {
  const parent = referenceRow.parentNode;
  parent.insertBefore(draggedRow, referenceRow);
  if (draggedChildren) parent.insertBefore(draggedChildren, referenceRow);
}

export function moveBlockAfter(draggedRow, draggedChildren, referenceRow) {
  const parent = referenceRow.parentNode;
  const afterNode = getNodeAfterBlock(referenceRow);
  parent.insertBefore(draggedRow, afterNode);
  if (draggedChildren) parent.insertBefore(draggedChildren, afterNode);
}

export function appendBlockToContainer(draggedRow, draggedChildren, container) {
  container.appendChild(draggedRow);
  if (draggedChildren) container.appendChild(draggedChildren);
}

export function isDescendantRow(parentRow, candidateRow) {
  const container = getChildrenContainer(parentRow);
  if (!container) return false;
  return container.contains(candidateRow);
}

export function updateRowLevel(row, delta) {
  const current = Number(row.getAttribute('level') || row.level || 1);
  const next = Math.max(1, current + delta);
  if (row.level !== next) row.level = next;
  row.setAttribute('level', next);
  const tree = row.querySelector('.creative-tree');
  if (tree) tree.dataset.level = String(next);
  row.requestUpdate?.();
}

export function applyLevelDelta(row, delta) {
  if (!row || delta === 0) return;
  updateRowLevel(row, delta);
  const childrenContainer = getChildrenContainer(row);
  if (!childrenContainer) return;
  const childRows = childrenContainer.querySelectorAll(':scope > creative-tree-row');
  childRows.forEach((childRow) => applyLevelDelta(childRow, delta));
}

export function setRowParent(row, parentId) {
  if (!row) return;
  if (parentId) {
    if (row.parentId !== parentId) row.parentId = parentId;
    row.setAttribute('parent-id', parentId);
  } else {
    row.parentId = null;
    row.removeAttribute('parent-id');
  }
  const tree = row.querySelector('.creative-tree');
  if (tree) {
    if (parentId) {
      tree.dataset.parentId = parentId;
    } else {
      delete tree.dataset.parentId;
    }
  }
  row.requestUpdate?.();
}

export function setRowRootState(row, isRoot) {
  if (!row) return;
  if (isRoot) {
    row.isRoot = true;
    row.setAttribute('is-root', '');
  } else {
    row.isRoot = false;
    row.removeAttribute('is-root');
  }
  row.requestUpdate?.();
}

export function setHasChildren(row, hasChildren) {
  if (!row) return;
  if (hasChildren) {
    row.hasChildren = true;
    row.setAttribute('has-children', '');
  } else {
    row.hasChildren = false;
    row.removeAttribute('has-children');
  }
  row.requestUpdate?.();
}

export function setExpanded(row, expanded, container) {
  if (!row) return;
  if (expanded) {
    row.expanded = true;
    row.setAttribute('expanded', '');
    if (container) {
      container.style.display = '';
      container.dataset.expanded = 'true';
      if (!container.dataset.loaded) container.dataset.loaded = 'true';
    }
  } else {
    row.expanded = false;
    row.removeAttribute('expanded');
    if (container) {
      container.style.display = 'none';
      container.dataset.expanded = 'false';
    }
  }
  row.requestUpdate?.();
}

export function syncParentHasChildren(parentId) {
  if (!parentId) return;
  const parentRow = document.querySelector(`creative-tree-row[creative-id="${parentId}"]`);
  if (!parentRow) return;
  const container = getChildrenContainer(parentRow);
  const hasChildren = !!(container && container.querySelector('creative-tree-row'));
  setHasChildren(parentRow, hasChildren);
  if (!hasChildren) {
    setExpanded(parentRow, false, container);
  }
}
