// Tree-DOM navigation & geometry helpers extracted from creative_row_editor.js.
//
// This is slice 2 of the creative_row_editor god-file decomposition (slice 1 was
// the save-queue single-flight/debounce cluster, already in creative_save_queue.js).
//
// Every function here operates purely on the DOM nodes passed as arguments (plus
// `document` for id/selector lookups) — none captures the editor closure's shared
// state (currentTree, form, parentInput, isDirty, pendingSave, uploadsPending, …).
// That is exactly why this cluster is a clean seam: it can be lifted out and unit
// tested against a jsdom fixture without standing up the whole inline editor.
//
// The cluster underpins the structural-move paths (levelUp / levelDown / addNew /
// move) that compute a node's parent, its before/after siblings, and its indent
// level — the inputs to the recurring "parentId loss / wrong ordering" bug class.
// Pinning them with characterization tests raises the floor under those moves.
//
// NOTE ON BINDING HAZARDS: none of these functions use setTimeout / setInterval /
// requestAnimationFrame / queueMicrotask, and none rely on `this`. They are plain
// functions invoked by name, so the "Illegal invocation" class of real-browser
// regression (a prior timer-extraction bug that jsdom could not catch) does not
// apply here. The only DOM writes are element mutations (insertBefore, appendChild,
// setAttribute, dataset, style, requestUpdate) invoked on the passed nodes.
import { treeRowElement, readRowLevel, buildChildrenLoadUrl } from './creative_row_editor_helpers';

export function creativeTreeElement(node) {
  if (!node) return null;
  if (node.classList && node.classList.contains('creative-tree')) return node;
  if (node.querySelector) {
    const inner = node.querySelector('.creative-tree');
    if (inner) return inner;
  }
  return null;
}

export function creativeIdFrom(node) {
  const treeEl = creativeTreeElement(node);
  if (treeEl && treeEl.dataset) {
    return treeEl.dataset.id || '';
  }
  if (node?.getAttribute) {
    return node.getAttribute('creative-id') || node.getAttribute('data-id') || '';
  }
  return '';
}

export function siblingTreeRow(row, direction) {
  if (!row) return null;
  const step = direction === 'previous' ? 'previousSibling' : 'nextSibling';
  let node = row[step];
  while (node) {
    if (node.nodeType === Node.TEXT_NODE) {
      node = node[step];
      continue;
    }
    if (node.matches?.('creative-tree-row')) return node;
    if (node.classList?.contains?.('creative-children')) {
      node = node[step];
      continue;
    }
    node = node[step];
  }
  return null;
}

export function siblingOrderingForRow(row) {
  const beforeRow = siblingTreeRow(row, 'next');
  const afterRow = siblingTreeRow(row, 'previous');
  return {
    beforeId: beforeRow ? creativeIdFrom(beforeRow) : '',
    afterId: afterRow ? creativeIdFrom(afterRow) : ''
  };
}

export function treeContainerElement(tree) {
  if (!tree) return null;
  const row = treeRowElement(tree);
  if (row && row.parentNode) return row.parentNode;
  return tree.parentNode;
}

export function nodeAfterTreeBlock(tree) {
  if (!tree) return null;
  const row = treeRowElement(tree);
  if (!row) return tree.nextSibling;
  let node = row.nextSibling;
  while (node && node.nodeType === Node.TEXT_NODE) node = node.nextSibling;
  const treeId = tree.dataset?.id;
  if (treeId) {
    const childrenContainer = document.getElementById(`creative-children-${treeId}`);
    if (childrenContainer && childrenContainer.parentNode === row.parentNode && node === childrenContainer) {
      node = childrenContainer.nextSibling;
      while (node && node.nodeType === Node.TEXT_NODE) node = node.nextSibling;
    }
  }
  return node;
}

export function normalizeRowNode(node) {
  if (!node) return null;
  if (node.matches && node.matches('creative-tree-row')) return node;
  if (node.classList && node.classList.contains('creative-tree')) {
    const row = treeRowElement(node);
    return row || node;
  }
  return node;
}

export function childrenContainerForTree(tree) {
  if (!tree) return null;
  const treeId = tree.dataset?.id;
  if (treeId) {
    const byId = document.getElementById(`creative-children-${treeId}`);
    if (byId) return byId;
  }
  if (tree.children && tree.children.length > 0) {
    for (const child of tree.children) {
      if (child && child.classList && child.classList.contains('creative-children')) {
        return child;
      }
    }
  }
  const row = treeRowElement(tree);
  if (row) {
    let sibling = row.nextElementSibling;
    while (sibling) {
      if (sibling.matches?.('creative-tree-row')) break;
      if (sibling.classList?.contains('creative-children')) return sibling;
      sibling = sibling.nextElementSibling;
    }
  }
  return null;
}

export function ensureChildrenContainer(tree) {
  if (!tree) return null;
  let container = childrenContainerForTree(tree);
  if (container) return container;
  const parentId = tree.dataset?.id;
  if (!parentId) return null;
  container = document.createElement('div');
  container.className = 'creative-children';
  container.id = `creative-children-${parentId}`;
  const parentRow = treeRowElement(tree);
  const parentLevel = readRowLevel(parentRow) || 1;
  const childLevel = parentLevel + 1;
  const selectModeActive = parentRow?.hasAttribute?.('select-mode') ? 1 : 0;
  container.dataset.loadUrl = buildChildrenLoadUrl(parentId, childLevel, selectModeActive);
  container.dataset.expanded = 'true';
  if (container.dataset.loaded) delete container.dataset.loaded;
  const row = treeRowElement(tree);
  const parentContainer = row?.parentNode || tree.parentNode;
  if (parentContainer) {
    const afterRow = row?.nextSibling;
    if (afterRow) {
      parentContainer.insertBefore(container, afterRow);
    } else {
      parentContainer.appendChild(container);
    }
  } else {
    tree.appendChild(container);
  }
  return container;
}

export function expandChildrenContainer(container) {
  if (!container) return;
  container.style.display = '';
  if (container.dataset) {
    container.dataset.expanded = 'true';
  }
}

export function moveTreeBlock(tree, targetContainer, referenceNode = null) {
  if (!tree || !targetContainer) return;
  const row = treeRowElement(tree);
  if (!row) return;
  const nodesToMove = [row];
  const childContainer = childrenContainerForTree(tree);
  if (childContainer) nodesToMove.push(childContainer);
  nodesToMove.forEach((node) => {
    if (!node) return;
    if (referenceNode) {
      targetContainer.insertBefore(node, referenceNode);
    } else {
      targetContainer.appendChild(node);
    }
  });
}

export function listAllTreeNodes() {
  const root = document.getElementById('creatives');
  if (root) return Array.from(root.querySelectorAll('.creative-tree'));
  return Array.from(document.querySelectorAll('.creative-tree'));
}

export function findPreviousTree(tree) {
  if (!tree) return null;
  const nodes = listAllTreeNodes();
  const index = nodes.indexOf(tree);
  if (index <= 0) return null;
  const currentLevel = getTreeLevel(tree);
  for (let i = index - 1; i >= 0; i--) {
    const candidate = nodes[i];
    if (!candidate) continue;
    const candidateLevel = getTreeLevel(candidate);
    if (candidateLevel === currentLevel) return candidate;
    if (candidateLevel < currentLevel) return null;
  }
  return null;
}

export function getTreeLevel(tree) {
  if (!tree) return 1;
  const levelValue = Number(tree.dataset?.level);
  if (!Number.isNaN(levelValue) && levelValue > 0) {
    return levelValue;
  }
  const row = treeRowElement(tree);
  return readRowLevel(row) || 1;
}

export function updateTreeLevels(tree, delta) {
  if (!tree || !delta) return;
  const currentLevel = Number(tree.dataset?.level) || 1;
  const nextLevel = Math.max(1, currentLevel + delta);
  tree.dataset.level = String(nextLevel);
  const row = treeRowElement(tree);
  if (row) {
    row.setAttribute('level', nextLevel);
    row.level = nextLevel;
    row.requestUpdate?.();
  }
  const container = childrenContainerForTree(tree);
  if (!container) return;
  Array.from(container.children || []).forEach((childRow) => {
    if (!childRow.matches?.('creative-tree-row')) return;
    const childTree = childRow.querySelector('.creative-tree');
    if (childTree) {
      updateTreeLevels(childTree, delta);
    }
  });
}

export function setTreeLevel(tree, targetLevel) {
  if (!tree || typeof targetLevel !== 'number') return;
  const currentLevel = Number(tree.dataset?.level) || 1;
  const delta = targetLevel - currentLevel;
  if (delta === 0) return;
  updateTreeLevels(tree, delta);
}

export function removeTreeElement(tree) {
  if (!tree) return;
  const row = treeRowElement(tree);
  if (row) {
    row.remove();
  } else if (tree.remove) {
    tree.remove();
  }
}
