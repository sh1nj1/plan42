import {
  DRAGGABLE_SELECTOR,
  clearDragHighlight,
  asTreeRow,
  getChildrenContainer,
  ensureChildrenContainer,
  appendBlockToContainer,
  moveBlockBefore,
  moveBlockAfter,
  isDescendantRow,
  applyLevelDelta,
  setRowParent,
  setRowRootState,
  setHasChildren,
  setExpanded,
  syncParentHasChildren,
} from './dom';
import {
  setDraggedState,
  getDraggedState,
  resetDraggedState,
  setLastDragOverRow,
  getLastDragOverRow,
  hasDraggedState,
} from './state';
import { createMoveContext, applyMove, revertMove } from './operations';
import { sendNewOrder, sendLinkedCreative } from '../../api/drag_drop.api';
import { initIndicator, showLinkHover, hideLinkHover } from './indicator';

const childZoneRatio = 0.3;
const coordPrecision = 5;

function relaxedCoord(value) {
  return Math.round(value / coordPrecision) * coordPrecision;
}

function handleDragStart(event) {
  const tree = event.target.closest(DRAGGABLE_SELECTOR);
  if (!tree || tree.draggable === false) return;
  const row = asTreeRow(tree);
  if (!row) return;
  const creativeId = row.getAttribute('creative-id');
  setDraggedState({
    tree,
    row,
    treeId: tree.id,
    creativeId,
    parentId: row.getAttribute('parent-id') || null,
    level: Number(row.getAttribute('level') || row.level || 1),
    isRoot: row.hasAttribute('is-root'),
  });
  event.dataTransfer.effectAllowed = 'move';
}

function handleDragOver(event) {
  const tree = event.target.closest(DRAGGABLE_SELECTOR);
  const lastRow = getLastDragOverRow();
  if (lastRow && lastRow !== tree) {
    clearDragHighlight(lastRow);
  }
  if (!tree || tree.draggable === false) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = 'move';

  const rect = tree.getBoundingClientRect();
  const topZone = relaxedCoord(rect.top + rect.height * childZoneRatio);
  const bottomZone = relaxedCoord(rect.bottom - rect.height * childZoneRatio);
  const y = relaxedCoord(event.clientY);

  if (y < topZone) {
    tree.classList.add('drag-over', 'drag-over-top');
    tree.classList.remove('drag-over-bottom', 'drag-over-child', 'child-drop-indicator-active');
  } else if (y > bottomZone) {
    tree.classList.add('drag-over', 'drag-over-bottom');
    tree.classList.remove('drag-over-top', 'drag-over-child', 'child-drop-indicator-active');
  } else {
    tree.classList.add('drag-over', 'drag-over-child', 'child-drop-indicator-active');
    tree.classList.remove('drag-over-top', 'drag-over-bottom');
  }

  if (event.shiftKey) {
    showLinkHover(event.clientX, event.clientY);
  } else {
    hideLinkHover();
  }

  setLastDragOverRow(tree);
}

function resetDrag() {
  resetDraggedState();
  hideLinkHover();
}

function handleDrop(event) {
  const targetTree = event.target.closest(DRAGGABLE_SELECTOR);
  const targetId = targetTree ? targetTree.id : '';
  clearDragHighlight(targetTree);
  clearDragHighlight(getLastDragOverRow());

  const draggedState = getDraggedState();

  if (!targetTree || targetTree.draggable === false || !draggedState) {
    resetDrag();
    return;
  }

  event.preventDefault();

  if (!targetId || draggedState.treeId === targetId) {
    resetDrag();
    return;
  }

  const targetRow = asTreeRow(targetTree);
  const draggedRow = draggedState.row;
  const draggedTree = draggedState.tree;
  if (!targetRow || !draggedRow || !draggedTree) {
    resetDrag();
    return;
  }

  if (isDescendantRow(draggedRow, targetRow)) {
    resetDrag();
    return;
  }

  const rect = targetTree.getBoundingClientRect();
  const topZone = relaxedCoord(rect.top + rect.height * childZoneRatio);
  const bottomZone = relaxedCoord(rect.bottom - rect.height * childZoneRatio);
  const y = relaxedCoord(event.clientY);

  let direction;
  if (y >= topZone && y <= bottomZone) {
    direction = 'child';
  } else if (y < topZone) {
    direction = 'up';
  } else {
    direction = 'down';
  }

  if (event.shiftKey) {
    const snapshot = { ...draggedState };
    resetDrag();
    sendLinkedCreative({
      draggedId: snapshot.creativeId,
      targetId: targetId.replace('creative-', ''),
      direction,
    })
      .then(() => window.location.reload())
      .catch((error) => console.error('Failed to create linked creative', error));
    return;
  }

  const draggedChildren = getChildrenContainer(draggedRow);
  const moveContext = createMoveContext(draggedState, targetRow, draggedChildren);

  const { newParentId } = applyMove({
    direction,
    targetRow,
    draggedState,
    draggedChildren,
    moveContext,
  });

  const draggedNumericId = draggedState.creativeId;

  sendNewOrder({
    draggedId: draggedNumericId,
    targetId: targetId.replace('creative-', ''),
    direction,
  })
    .then((response) => {
      if (!response.ok) {
        revertMove(moveContext, newParentId);
      }
    })
    .catch((error) => {
      console.error('Failed to update order', error);
      revertMove(moveContext, newParentId);
    });

  resetDrag();
}

function handleDragLeave(event) {
  const tree = event.target.closest(DRAGGABLE_SELECTOR);
  if (!tree || tree.draggable === false) return;
  clearDragHighlight(tree);
  hideLinkHover();
}

function handleDragEnd() {
  hideLinkHover();
}

export function registerGlobalHandlers() {
  initIndicator();

  window.handleDragStart = handleDragStart;
  window.handleDragOver = handleDragOver;
  window.handleDrop = handleDrop;
  window.handleDragLeave = handleDragLeave;

  document.addEventListener('dragend', handleDragEnd);
}

export function hasActiveDrag() {
  return hasDraggedState();
}
