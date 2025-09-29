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

const TRANSFER_MIME_TYPE = 'application/x-plan42-creative';
const DRAG_TOKEN_STORAGE_KEY = 'plan42.dragToken';
const INVALID_DROP_MESSAGE =
  'We could not verify that drop. Please refresh the page and try again.';

let cachedDragToken;

function generateDragToken() {
  if (typeof window === 'undefined') return null;

  const fallback = () =>
    `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;

  try {
    const { crypto } = window;
    if (crypto && typeof crypto.randomUUID === 'function') {
      return crypto.randomUUID();
    }
  } catch (error) {
    console.error('Failed to access crypto API for drag token generation', error);
  }

  return fallback();
}

function readStoredDragToken() {
  if (cachedDragToken) return cachedDragToken;
  if (typeof window === 'undefined') return null;

  try {
    const storage = window.localStorage;
    if (!storage) return null;

    const storedToken = storage.getItem(DRAG_TOKEN_STORAGE_KEY);
    if (storedToken) {
      cachedDragToken = storedToken;
    }

    return cachedDragToken || null;
  } catch (error) {
    console.error('Failed to read drag session token from storage', error);
    return null;
  }
}

function ensureDragSessionToken() {
  if (typeof window === 'undefined') return null;

  const existing = readStoredDragToken();
  if (existing) return existing;

  try {
    const storage = window.localStorage;
    if (!storage) return null;

    const freshToken = generateDragToken();
    if (!freshToken) return null;

    storage.setItem(DRAG_TOKEN_STORAGE_KEY, freshToken);
    cachedDragToken = freshToken;
    return freshToken;
  } catch (error) {
    console.error('Failed to persist drag session token', error);
    return null;
  }
}

function relaxedCoord(value) {
  return Math.round(value / coordPrecision) * coordPrecision;
}

function serializeDragState(state, sessionToken) {
  if (!sessionToken) return null;

  try {
    return JSON.stringify({
      creativeId: state.creativeId,
      treeId: state.treeId,
      parentId: state.parentId,
      level: state.level,
      isRoot: state.isRoot,
      token: sessionToken,
    });
  } catch (error) {
    console.error('Failed to serialize drag state', error);
    return null;
  }
}

function parseDragState(data) {
  if (!data) return null;

  try {
    const parsed = JSON.parse(data);
    if (parsed && parsed.creativeId && parsed.treeId) {
      const expectedToken = readStoredDragToken();
      if (!expectedToken || parsed.token !== expectedToken) {
        return null;
      }

      const { creativeId, treeId, parentId = null, level, isRoot } = parsed;
      return { creativeId, treeId, parentId, level, isRoot };
    }
  } catch (error) {
    console.error('Failed to parse drag data', error);
  }

  return null;
}

function getDraggedContext(event) {
  const existing = getDraggedState();
  const transfer = event.dataTransfer;
  const transferTypes = transfer?.types
    ? new Set(Array.from(transfer.types))
    : new Set();
  const hasTrustedPayload = transferTypes.has(TRANSFER_MIME_TYPE);

  const rawData = hasTrustedPayload ? transfer.getData(TRANSFER_MIME_TYPE) : null;
  const parsed = parseDragState(rawData);
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
  if (typeof window !== 'undefined' && typeof window.alert === 'function') {
    window.alert(INVALID_DROP_MESSAGE);
  }
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

  const sessionToken = ensureDragSessionToken();
  const serialized = serializeDragState(getDraggedState(), sessionToken);
  if (serialized) {
    event.dataTransfer.setData(TRANSFER_MIME_TYPE, serialized);
    event.dataTransfer.setData('text/plain', serialized);
  }
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
  const draggedRow = isExternal ? null : draggedState.row;
  const draggedTree = isExternal ? null : draggedState.tree;
  if (!targetRow || (!isExternal && (!draggedRow || !draggedTree))) {
    resetDrag();
    return;
  }

  if (!isExternal && isDescendantRow(draggedRow, targetRow)) {
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

  let moveContext = null;
  let newParentId = null;
  let draggedChildren = null;

  if (!isExternal) {
    draggedChildren = getChildrenContainer(draggedRow);
    moveContext = createMoveContext(draggedState, targetRow, draggedChildren);

    ({ newParentId } = applyMove({
      direction,
      targetRow,
      draggedState,
      draggedChildren,
      moveContext,
    }));
  }

  const draggedNumericId = draggedState.creativeId;

  resetDrag();

  const finalizeDrop = () => {
    if (isExternal) {
      window.location.reload();
    }
  };

  sendNewOrder({
    draggedId: draggedNumericId,
    targetId: targetId.replace('creative-', ''),
    direction,
  })
    .then((response) => {
      if (!response.ok) {
        if (!isExternal) {
          revertMove(moveContext, newParentId);
        }
      }
    })
    .catch((error) => {
      console.error('Failed to update order', error);
      if (!isExternal) {
        revertMove(moveContext, newParentId);
      }
    })
    .finally(finalizeDrop);
}

function handleDragLeave(event) {
  const tree = event.target.closest(DRAGGABLE_SELECTOR);
  if (!tree || tree.draggable === false) return;
  clearDragHighlight(tree);
  hideLinkHover();
}

function handleDragEnd() {
  resetDrag();
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
