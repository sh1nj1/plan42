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
const DROP_EVENT_NAME = 'plan42:creative-drop';
const DROP_MESSAGE_TYPE = 'creative-drop-complete';
const DROP_CHANNEL_NAME = 'plan42:creative-drop';

let dropChannel = null;
let dropHandlersInitialized = false;

function getWindowIdentifier() {
  if (typeof window === 'undefined') return 'plan42-ssr';

  const storageKey = 'plan42:drag-drop-window-id';

  try {
    const existing = window.sessionStorage?.getItem(storageKey);
    if (existing) return existing;

    const generated =
      (window.crypto?.randomUUID && window.crypto.randomUUID()) ||
      `win-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    window.sessionStorage?.setItem(storageKey, generated);
    return generated;
  } catch (error) {
    return `win-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  }
}

const windowIdentifier = getWindowIdentifier();

function relaxedCoord(value) {
  return Math.round(value / coordPrecision) * coordPrecision;
}

function serializeDragState(state) {
  try {
    return JSON.stringify({
      creativeId: state.creativeId,
      treeId: state.treeId,
      parentId: state.parentId,
      level: state.level,
      isRoot: state.isRoot,
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
      return parsed;
    }
  } catch (error) {
    console.error('Failed to parse drag data', error);
  }

  return null;
}

function ensureDropChannel() {
  if (dropHandlersInitialized || typeof window === 'undefined') return;

  dropHandlersInitialized = true;

  if (window.BroadcastChannel) {
    try {
      dropChannel = new BroadcastChannel(DROP_CHANNEL_NAME);
      dropChannel.addEventListener('message', (event) => {
        if (!event) return;
        handleDropSignal(event.data);
      });
    } catch (error) {
      console.error('Failed to create drag drop channel', error);
    }
  }

  window.addEventListener(DROP_EVENT_NAME, (event) => {
    handleDropSignal(event?.detail);
  });
}

function broadcastDropSignal(detail) {
  if (!detail) return;

  const payload = {
    ...detail,
    type: DROP_MESSAGE_TYPE,
    sourceWindowId: windowIdentifier,
  };

  window.dispatchEvent(new CustomEvent(DROP_EVENT_NAME, { detail: payload }));
  if (dropChannel) {
    try {
      dropChannel.postMessage(payload);
    } catch (error) {
      console.error('Failed to broadcast drop signal', error);
    }
  }
}

function handleDropSignal(data) {
  if (!data || data.type !== DROP_MESSAGE_TYPE) return;
  if (data.sourceWindowId === windowIdentifier) return;

  applyRemoteDrop(data);
}

function applyRemoteDrop(payload) {
  const { creativeId, targetId, direction, draggedState } = payload;
  if (!creativeId || !targetId || !direction || !draggedState) return;

  const draggedRow = document.querySelector(
    `creative-tree-row[creative-id="${creativeId}"]`
  );
  if (!draggedRow) return;

  const targetTree = document.getElementById(targetId);
  if (!targetTree) return;

  const targetRow = asTreeRow(targetTree);
  if (!targetRow) return;

  const sanitizedState = {
    row: draggedRow,
    tree: document.getElementById(draggedState.treeId) || null,
    treeId: draggedState.treeId,
    creativeId: draggedState.creativeId,
    parentId: draggedState.parentId,
    level:
      Number(draggedState.level) ||
      Number(draggedRow.getAttribute('level') || draggedRow.level || 1),
    isRoot: !!draggedState.isRoot,
  };

  const draggedChildren = getChildrenContainer(draggedRow);
  const moveContext = createMoveContext(sanitizedState, targetRow, draggedChildren);

  applyMove({
    direction,
    targetRow,
    draggedState: sanitizedState,
    draggedChildren,
    moveContext,
  });

  resetDrag();
}

function getDraggedContext(event) {
  const existing = getDraggedState();
  if (existing) {
    return { draggedState: existing, isExternal: false };
  }

  const transfer = event.dataTransfer;
  if (!transfer) return { draggedState: null, isExternal: false };

  const rawData =
    transfer.getData(TRANSFER_MIME_TYPE) || transfer.getData('text/plain');
  const parsed = parseDragState(rawData);

  if (!parsed) {
    return { draggedState: null, isExternal: false };
  }

  return { draggedState: parsed, isExternal: true };
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

  const serialized = serializeDragState(getDraggedState());
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

  const { draggedState, isExternal } = getDraggedContext(event);

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

  const dropSignalDetail = {
    creativeId: draggedState.creativeId,
    targetId,
    direction,
    draggedState: {
      creativeId: draggedState.creativeId,
      treeId: draggedState.treeId,
      parentId: draggedState.parentId,
      level: draggedState.level,
      isRoot: draggedState.isRoot,
    },
  };

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

  if (newParentId === null) {
    if (direction === 'child') {
      newParentId = targetRow.getAttribute('creative-id');
    } else {
      newParentId = targetRow.getAttribute('parent-id') || null;
    }
  }

  dropSignalDetail.newParentId = newParentId;

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
      } else {
        broadcastDropSignal(dropSignalDetail);
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

  ensureDropChannel();

  window.handleDragStart = handleDragStart;
  window.handleDragOver = handleDragOver;
  window.handleDrop = handleDrop;
  window.handleDragLeave = handleDragLeave;

  document.addEventListener('dragend', handleDragEnd);
}

export function hasActiveDrag() {
  return hasDraggedState();
}
