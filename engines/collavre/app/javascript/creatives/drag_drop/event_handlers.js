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
import * as dragState from './state';
import { createMoveContext, applyMove, revertMove } from './operations';
import { sendNewOrder, sendLinkedCreative, sendTopicMove } from '../../lib/api/drag_drop';
import { initIndicator, showLinkHover, hideLinkHover } from './indicator';
import { showMissingMembersPopup } from '../topic_move_members_popup';
import { alertDialog } from '../../lib/utils/dialog';
import { restoreTreeEmptyState } from '../../modules/creative_tree_empty_state';
import { getDragKind, readDragData, writeDragData } from '../../lib/dnd/envelope';
import { getVerticalDropPosition } from '../../lib/dnd/hit_test';
import {
  DROP_COMPLETED_EVENT,
  dispatchDropCompletion,
  emitDropSignal,
  ensureDragWindowId,
  readDragWindowId,
  readDropSignal,
} from '../../lib/dnd/session';

const coordPrecision = 5;

const INVALID_DROP_MESSAGE =
  'We could not verify that drop. Please refresh the page and try again.';

function getRowByCreativeId(creativeId) {
  if (typeof document === 'undefined' || !creativeId) return null;
  return document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`);
}

function collectSelectedCreativeIds(activeCreativeId) {
  if (typeof document === 'undefined') {
    return activeCreativeId ? [String(activeCreativeId)] : [];
  }

  const seen = new Set();
  const ids = [];

  const selectedCheckboxes = document.querySelectorAll('.select-creative-checkbox:checked');
  selectedCheckboxes.forEach((checkbox) => {
    const value = checkbox?.value;
    if (!value) return;
    const str = String(value);
    if (seen.has(str)) return;
    seen.add(str);
    ids.push(str);
  });

  if (activeCreativeId) {
    const str = String(activeCreativeId);
    if (!seen.has(str)) {
      ids.push(str);
    }
  }

  return ids;
}

function resolveDraggedIds(state) {
  if (!state) return [];

  const list = Array.isArray(state.selectedCreativeIds)
    ? state.selectedCreativeIds
    : [];
  const seen = new Set();
  const result = [];

  [...list, state.creativeId].forEach((id) => {
    if (!id && id !== 0) return;
    const str = String(id);
    if (seen.has(str)) return;
    seen.add(str);
    result.push(str);
  });

  return result;
}

function resolveDraggedStateFromDom(state) {
  if (!state) return null;
  if (typeof document === 'undefined') return null;

  const { creativeId, treeId = null } = state;
  if (!creativeId) return null;

  let tree = treeId ? document.getElementById(treeId) : null;
  let row = tree ? asTreeRow(tree) : null;

  if (!row) {
    row = getRowByCreativeId(creativeId);
    tree = row ? row.querySelector(DRAGGABLE_SELECTOR) : tree;
  }

  if (!row || !tree) return null;

  const parentId = row.getAttribute('parent-id') || null;
  const level = Number(row.getAttribute('level') || row.level || state.level || 1);
  const isRoot = row.hasAttribute('is-root');

  return {
    ...state,
    tree,
    treeId: tree.id || state.treeId || null,
    row,
    parentId,
    level,
    isRoot,
  };
}

function resolveTargetTree(targetTreeId) {
  if (typeof document === 'undefined' || !targetTreeId) return null;
  const tree = document.getElementById(targetTreeId);
  if (!tree) return null;
  const row = asTreeRow(tree);
  if (!row) return null;
  return { tree, row };
}

function relaxedCoord(value) {
  return Math.round(value / coordPrecision) * coordPrecision;
}

function removeDroppedCreative({ creativeId, treeId }) {
  if (typeof document === 'undefined') return;

  const tree = treeId ? document.getElementById(treeId) : null;
  const row = tree ? asTreeRow(tree) : null;
  const fallbackRow = getRowByCreativeId(creativeId);
  const targetRow = row || fallbackRow;
  if (!targetRow) return;

  const parentId = targetRow.getAttribute('parent-id') || null;
  const childrenContainer = getChildrenContainer(targetRow);
  if (childrenContainer) {
    childrenContainer.remove();
  }
  targetRow.remove();

  syncParentHasChildren(parentId);
  // Dropping the last row into another window empties this tree, and the move
  // is not a destroy — no broadcast repairs the placeholder here.
  restoreTreeEmptyState();
}

function syncSourceWindowDrop(detail) {
  const { creativeId, treeId = null, direction, targetTreeId = null } = detail;
  if (!creativeId || !direction || !targetTreeId) {
    removeDroppedCreative({ creativeId, treeId });
    return;
  }

  const resolvedDraggedState = resolveDraggedStateFromDom({ creativeId, treeId });
  if (!resolvedDraggedState) {
    removeDroppedCreative({ creativeId, treeId });
    return;
  }

  const target = resolveTargetTree(targetTreeId);
  if (!target) {
    removeDroppedCreative({ creativeId, treeId });
    return;
  }

  if (isDescendantRow(resolvedDraggedState.row, target.row)) {
    removeDroppedCreative({ creativeId, treeId });
    return;
  }

  const draggedChildren = getChildrenContainer(resolvedDraggedState.row);
  const moveContext = createMoveContext(
    resolvedDraggedState,
    target.row,
    draggedChildren
  );

  let newParentId = resolvedDraggedState.parentId;

  try {
    ({ newParentId } = applyMove({
      direction,
      targetRow: target.row,
      draggedState: resolvedDraggedState,
      draggedChildren,
      moveContext,
    }));
  } catch (error) {
    console.error('Failed to synchronize drop in source window', error);
    revertMove(moveContext, newParentId);
  }
}

function handleStorageChange(event) {
  const payload = readDropSignal(event);
  if (!payload) return;

  const { creativeId } = payload;
  if (!creativeId) return;

  dispatchDropCompletion({
    ...payload,
    context: 'source',
  });
}

function handleDropCompletionEvent(event) {
  if (!event || !event.detail) return;

  const detail = event.detail;
  const { creativeId, treeId = null, sourceWindowId = null, context } = detail;
  if (!creativeId || !context) return;

  const windowId = readDragWindowId();
  if (!windowId || sourceWindowId !== windowId) {
    return;
  }

  if (context === 'source') {
    syncSourceWindowDrop(detail);
  }
}

function getDraggedContext(event) {
  const existing = getDraggedState();
  const transfer = event.dataTransfer;
  const hasTrustedPayload = getDragKind(transfer) === 'creative';
  const data = readDragData(transfer);
  const parsed = data?.kind === 'creative'
    ? { ...data.payload, selectedCreativeIds: data.ids }
    : null;
  const wasRejectedPayload = hasTrustedPayload && !parsed;

  if (existing) {
    if (parsed && parsed.creativeId === existing.creativeId && parsed.treeId === existing.treeId) {
      return { draggedState: existing, isExternal: false, wasRejectedPayload };
    }

    if (parsed) {
      return { draggedState: parsed, isExternal: true, wasRejectedPayload };
    }

    if (hasTrustedPayload) {
      return { draggedState: null, isExternal: false, wasRejectedPayload };
    }

    return { draggedState: existing, isExternal: false, wasRejectedPayload };
  }

  if (!parsed) {
    return { draggedState: null, isExternal: false, wasRejectedPayload };
  }

  return { draggedState: parsed, isExternal: true, wasRejectedPayload };
}

function notifyInvalidDrop() {
  console.error('Rejected invalid creative drop payload');
  alertDialog(INVALID_DROP_MESSAGE);
}

import { attachBundleDragImage } from '../../utils/drag_bundle_image.js';

function getCreativeText(id) {
  if (typeof document === 'undefined') return '';
  const rowEl = document.querySelector(`creative-tree-row[creative-id="${id}"]`);
  if (!rowEl) return '';
  const content = rowEl.querySelector('.creative-content');
  return content ? content.textContent.trim() : '';
}

export function handleDragStart(event) {
  const tree = event.target.closest(DRAGGABLE_SELECTOR);
  if (!tree || tree.draggable === false) return;
  const row = asTreeRow(tree);
  if (!row) return;
  const windowId = ensureDragWindowId();
  const creativeId = row.getAttribute('creative-id');
  const selectedCreativeIds = collectSelectedCreativeIds(creativeId);
  setDraggedState({
    tree,
    row,
    treeId: tree.id,
    creativeId,
    parentId: row.getAttribute('parent-id') || null,
    level: Number(row.getAttribute('level') || row.level || 1),
    isRoot: row.hasAttribute('is-root'),
    sourceWindowId: windowId,
    selectedCreativeIds,
  });
  event.dataTransfer.effectAllowed = 'move';

  // Custom bundle drag image for multi-select
  if (selectedCreativeIds.length > 1) {
    attachBundleDragImage(event, selectedCreativeIds.length, getCreativeText(creativeId));
  }

  const state = getDraggedState();
  writeDragData(event.dataTransfer, {
    kind: 'creative',
    ids: selectedCreativeIds,
    payload: {
      creativeId: state.creativeId,
      treeId: state.treeId,
      parentId: state.parentId,
      level: state.level,
      isRoot: state.isRoot,
      sourceWindowId: state.sourceWindowId,
      selectedCreativeIds: state.selectedCreativeIds,
    },
  });
}

export function handleDragOver(event) {
  const tree = event.target.closest(DRAGGABLE_SELECTOR);
  const lastRow = getLastDragOverRow();
  if (lastRow && lastRow !== tree) {
    clearDragHighlight(lastRow);
    setLastDragOverRow(null);
  }
  if (!tree || tree.draggable === false) return;

  const dragKind = getDragKind(event.dataTransfer);

  // Topic move drag: always show as child drop target
  if (dragKind === 'topic') {
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
    tree.classList.add('drag-over', 'drag-over-child', 'child-drop-indicator-active');
    tree.classList.remove('drag-over-top', 'drag-over-bottom');
    setLastDragOverRow(tree, 'child');
    return;
  }

  if (dragKind !== 'creative') return;

  event.preventDefault();
  event.dataTransfer.dropEffect = 'move';

  const previousPosition = getLastDragOverRow() === tree
    ? dragState.getLastDragOverPosition?.() || null
    : null;

  const position = getVerticalDropPosition({
    clientY: event.clientY,
    rect: tree.getBoundingClientRect(),
    previousPosition,
  });

  if (position === 'up') {
    tree.classList.add('drag-over', 'drag-over-top');
    tree.classList.remove('drag-over-bottom', 'drag-over-child', 'child-drop-indicator-active');
  } else if (position === 'down') {
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

  setLastDragOverRow(tree, position);
}

function resetDrag() {
  resetDraggedState();
  hideLinkHover();
}

export function handleDrop(event) {
  const targetTree = event.target.closest(DRAGGABLE_SELECTOR);
  const targetId = targetTree ? targetTree.id : '';

  // Handle topic move drop
  const dragData = readDragData(event.dataTransfer);
  if (dragData?.kind === 'topic' && targetTree) {
    event.preventDefault();
    clearDragHighlight(targetTree);
    clearDragHighlight(getLastDragOverRow());
    setLastDragOverRow(null);

    try {
      const topicId = dragData.ids[0];
      const { sourceCreativeId } = dragData.payload;
      const targetCreativeId = targetId.replace('creative-', '');

      if (sourceCreativeId === targetCreativeId) return;

      sendTopicMove({ topicId, sourceCreativeId, targetCreativeId })
        .then((data) => {
          // Dispatch event so topic list refreshes
          window.dispatchEvent(new CustomEvent('collavre:topic-moved', {
            detail: { topicId, sourceCreativeId, targetCreativeId }
          }));

          // The server releases a primary agent that has no feedback access at
          // the new location, because an exclusive pin the agent cannot honor
          // would silence the topic. Say so — otherwise the avatar just
          // disappears mid-drag with no explanation.
          if (data && data.released_primary_agent && data.released_primary_agent.message) {
            alertDialog(data.released_primary_agent.message);
          }

          // Offer to re-add members who lose access at the new location.
          if (data && Array.isArray(data.missing_members) && data.missing_members.length > 0) {
            showMissingMembersPopup({
              members: data.missing_members,
              targetCreativeId: data.target_creative_id || targetCreativeId,
              targetCreativeName: data.target_creative_name,
            });
          }
        })
        .catch((error) => {
          console.error('Failed to move topic', error);
          alertDialog(error.message || 'Failed to move topic');
        });
    } catch (error) {
      console.error('Failed to parse topic move data', error);
    }
    return;
  }

  const previewedDirection = targetTree && getLastDragOverRow() === targetTree
    ? dragState.getLastDragOverPosition?.() || null
    : null;

  clearDragHighlight(targetTree);
  clearDragHighlight(getLastDragOverRow());

  const { draggedState, isExternal, wasRejectedPayload } = getDraggedContext(event);

  if (!targetTree || targetTree.draggable === false) {
    resetDrag();
    return;
  }

  if (!draggedState) {
    if (wasRejectedPayload) {
      notifyInvalidDrop();
    }
    resetDrag();
    return;
  }

  event.preventDefault();

  if (!targetId || draggedState.treeId === targetId) {
    resetDrag();
    return;
  }

  const targetRow = asTreeRow(targetTree);
  const resolvedDraggedState =
    isExternal && draggedState ? resolveDraggedStateFromDom(draggedState) : draggedState;
  const hasDomState = !!resolvedDraggedState?.row && !!resolvedDraggedState?.tree;
  const draggedRow = hasDomState ? resolvedDraggedState.row : null;
  if (!targetRow) {
    resetDrag();
    return;
  }

  const baseDraggedState = resolvedDraggedState || draggedState;
  const draggedIds = resolveDraggedIds(baseDraggedState);
  const isMultiDrag = draggedIds.length > 1;

  if (draggedRow && isDescendantRow(draggedRow, targetRow)) {
    resetDrag();
    return;
  }

  if (isMultiDrag) {
    const targetCreativeId = targetRow.getAttribute('creative-id');
    if (draggedIds.includes(String(targetCreativeId))) {
      resetDrag();
      return;
    }

    if (typeof document !== 'undefined') {
      const selectedRows = draggedIds
        .map((id) => {
          if (draggedRow && String(resolvedDraggedState?.creativeId) === String(id)) {
            return draggedRow;
          }
          const treeElement = document.getElementById(`creative-${id}`);
          return treeElement ? asTreeRow(treeElement) : null;
        })
        .filter(Boolean);

      const targetWithinSelection = selectedRows.some(
        (rowEl) => rowEl === targetRow || isDescendantRow(rowEl, targetRow)
      );

      if (targetWithinSelection) {
        resetDrag();
        return;
      }
    }
  }

  let direction = previewedDirection;
  if (!direction) {
    // Fallback calculation
    direction = getVerticalDropPosition({
      clientY: event.clientY,
      rect: targetTree.getBoundingClientRect(),
    });
    if (!direction) {
      resetDrag();
      return;
    }
  }

  if (event.shiftKey) {
    const snapshot = { ...draggedState };
    resetDrag();

    if (isMultiDrag) {
      // Handle multiple linked creatives
      const promises = draggedIds.map(draggedId =>
        sendLinkedCreative({
          draggedId,
          targetId: targetId.replace('creative-', ''),
          direction,
        })
      );

      Promise.all(promises)
        .then(() => window.location.reload())
        .catch((error) => console.error('Failed to create linked creatives', error));
    } else {
      // Handle single linked creative
      sendLinkedCreative({
        draggedId: snapshot.creativeId,
        targetId: targetId.replace('creative-', ''),
        direction,
      })
        .then(() => window.location.reload())
        .catch((error) => console.error('Failed to create linked creative', error));
    }
    return;
  }

  let moveContext = null;
  let newParentId = null;
  let draggedChildren = null;

  if (draggedRow && !isMultiDrag) {
    draggedChildren = getChildrenContainer(draggedRow);
    moveContext = createMoveContext(
      resolvedDraggedState,
      targetRow,
      draggedChildren
    );

    ({ newParentId } = applyMove({
      direction,
      targetRow,
      draggedState: resolvedDraggedState,
      draggedChildren,
      moveContext,
    }));
  }

  const draggedNumericId = draggedState.creativeId;
  const dropSignalDetails = isMultiDrag
    ? null
    : {
      creativeId: draggedNumericId,
      treeId: draggedState.treeId,
      sourceWindowId: draggedState.sourceWindowId,
      targetTreeId: targetId,
      direction,
    };

  resetDrag();

  const shouldReloadOnFinalize = isExternal && !moveContext;

  const finalizeDrop = () => {
    if (shouldReloadOnFinalize) {
      window.location.reload();
    }
  };

  const reorderPayload = {
    targetId: targetId.replace('creative-', ''),
    direction,
  };

  if (isMultiDrag) {
    reorderPayload.draggedIds = draggedIds;
  } else {
    reorderPayload.draggedId = draggedNumericId;
  }

  sendNewOrder(reorderPayload)
    .then((response) => {
      if (!response.ok) {
        if (moveContext) {
          revertMove(moveContext, newParentId);
        }
        return;
      }

      if (isMultiDrag) {
        window.location.reload();
        return;
      }

      if (dropSignalDetails?.sourceWindowId) {
        emitDropSignal(dropSignalDetails);
        dispatchDropCompletion({ ...dropSignalDetails, context: 'target' });
      }
    })
    .catch((error) => {
      console.error('Failed to update order', error);
      if (moveContext) {
        revertMove(moveContext, newParentId);
      }
    })
    .finally(finalizeDrop);
}

export function handleDragLeave(event) {
  const tree = event.target.closest(DRAGGABLE_SELECTOR);
  if (!tree || tree.draggable === false) return;
  clearDragHighlight(tree);
  if (getLastDragOverRow() === tree) setLastDragOverRow(null);
  hideLinkHover();
}

function handleDragEnd() {
  resetDrag();
}

export function addGlobalListeners() {
  document.addEventListener('dragend', handleDragEnd);
  window.addEventListener('storage', handleStorageChange);
  window.addEventListener(DROP_COMPLETED_EVENT, handleDropCompletionEvent);
}

export function removeGlobalListeners() {
  document.removeEventListener('dragend', handleDragEnd);
  window.removeEventListener('storage', handleStorageChange);
  window.removeEventListener(DROP_COMPLETED_EVENT, handleDropCompletionEvent);
}

export function registerGlobalHandlers() {
  initIndicator();
  addGlobalListeners();
}

export function hasActiveDrag() {
  return hasDraggedState();
}
