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
const DROP_SIGNAL_STORAGE_KEY = 'plan42.dragDropSignal';
const WINDOW_ID_SESSION_KEY = 'plan42.dragWindowId';
const INVALID_DROP_MESSAGE =
  'We could not verify that drop. Please refresh the page and try again.';
const DROP_COMPLETED_EVENT = 'plan42:creative-drop-complete';

let cachedDragToken;
let cachedWindowId;

function getRowByCreativeId(creativeId) {
  if (typeof document === 'undefined' || !creativeId) return null;
  return document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`);
}

function generateRandomIdentifier(context) {
  const fallback = () =>
    `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;

  if (typeof window === 'undefined') return fallback();

  try {
    const { crypto } = window;
    if (crypto && typeof crypto.randomUUID === 'function') {
      return crypto.randomUUID();
    }
  } catch (error) {
    if (context) {
      console.error(`Failed to access crypto API for ${context}`, error);
    } else {
      console.error('Failed to access crypto API for identifier generation', error);
    }
  }

  return fallback();
}

function generateDragToken() {
  if (typeof window === 'undefined') return null;

  return generateRandomIdentifier('drag token generation');
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

function readWindowId() {
  if (cachedWindowId) return cachedWindowId;
  if (typeof window === 'undefined') return null;

  try {
    const storage = window.sessionStorage;
    if (!storage) return null;

    const stored = storage.getItem(WINDOW_ID_SESSION_KEY);
    if (stored) {
      cachedWindowId = stored;
    }
    return cachedWindowId || null;
  } catch (error) {
    console.error('Failed to read drag window id from session storage', error);
    return cachedWindowId || null;
  }
}

function ensureWindowId() {
  if (typeof window === 'undefined') return null;

  const existing = readWindowId();
  if (existing) return existing;

  const freshId = generateRandomIdentifier('drag window id generation');
  if (!freshId) return null;

  try {
    const storage = window.sessionStorage;
    storage?.setItem(WINDOW_ID_SESSION_KEY, freshId);
    cachedWindowId = freshId;
    return freshId;
  } catch (error) {
    console.error('Failed to persist drag window id', error);
    cachedWindowId = freshId;
    return freshId;
  }
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
      sourceWindowId: state.sourceWindowId,
      selectedCreativeIds: Array.isArray(state.selectedCreativeIds)
        ? state.selectedCreativeIds
        : [],
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

      const {
        creativeId,
        treeId,
        parentId = null,
        level,
        isRoot,
        sourceWindowId = null,
        selectedCreativeIds = [],
      } = parsed;
      const normalizedSelected = Array.isArray(selectedCreativeIds)
        ? selectedCreativeIds.map((id) => String(id)).filter((value, index, array) => array.indexOf(value) === index)
        : [];
      return {
        creativeId,
        treeId,
        parentId,
        level,
        isRoot,
        sourceWindowId,
        selectedCreativeIds: normalizedSelected,
      };
    }
  } catch (error) {
    console.error('Failed to parse drag data', error);
  }

  return null;
}

function emitDropSignal(detail) {
  if (typeof window === 'undefined') return;

  const sessionToken = readStoredDragToken();
  if (!sessionToken) return;

  try {
    const storage = window.localStorage;
    if (!storage) return;

    const payload = JSON.stringify({
      ...detail,
      sessionToken,
      nonce: generateRandomIdentifier('drag drop signal'),
    });

    storage.setItem(DROP_SIGNAL_STORAGE_KEY, payload);
    storage.removeItem(DROP_SIGNAL_STORAGE_KEY);
  } catch (error) {
    console.error('Failed to broadcast drop completion signal', error);
  }
}

function dispatchDropCompletion(detail) {
  if (typeof window === 'undefined') return;

  try {
    window.dispatchEvent(
      new CustomEvent(DROP_COMPLETED_EVENT, {
        detail,
      })
    );
  } catch (error) {
    console.error('Failed to dispatch creative drop completion event', error);
  }
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
  if (!event || event.key !== DROP_SIGNAL_STORAGE_KEY || !event.newValue) {
    return;
  }

  let payload;
  try {
    payload = JSON.parse(event.newValue);
  } catch (error) {
    console.error('Failed to parse drop completion payload', error);
    return;
  }

  const expectedToken = readStoredDragToken();
  if (!expectedToken || payload.sessionToken !== expectedToken) {
    return;
  }

  const windowId = readWindowId();
  if (!windowId || payload.sourceWindowId !== windowId) {
    return;
  }

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

  const windowId = readWindowId();
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
  const windowId = ensureWindowId();
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
    if (isMultiDrag) {
      resetDrag();
      console.warn('Linking multiple creatives at once is not supported.');
      return;
    }
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
  window.addEventListener('storage', handleStorageChange);
  window.addEventListener(DROP_COMPLETED_EVENT, handleDropCompletionEvent);
}

export function hasActiveDrag() {
  return hasDraggedState();
}
