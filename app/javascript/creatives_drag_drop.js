if (!window.creativesDragDropInitialized) {
  window.creativesDragDropInitialized = true;

  const childZoneRatio = 0.3;
  const coordPrecision = 5;
  const draggableClassName = '.creative-tree';

  let draggedState = null;
  let lastDragOverRow = null;

  const crossWindowDragStorageKey = 'creatives.dragState';
  const crossWindowDropStorageKey = 'creatives.dropBroadcast';
  const crossWindowPayloadTTL = 30000;
  const crossWindowWindowId = ensureCrossWindowWindowId();
  let pendingCrossWindowReload = false;

  function relaxedCoord(value) {
    return Math.round(value / coordPrecision) * coordPrecision;
  }

  const linkHoverIndicator = document.createElement('div');
  linkHoverIndicator.className = 'creative-link-drop-indicator';
  linkHoverIndicator.textContent = '-->';

  function appendLinkHoverIndicator() {
    (document.body || document.documentElement).appendChild(linkHoverIndicator);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', appendLinkHoverIndicator, { once: true });
  } else {
    appendLinkHoverIndicator();
  }

  function showLinkHover(x, y) {
    linkHoverIndicator.style.display = 'block';
    linkHoverIndicator.style.left = `${x}px`;
    linkHoverIndicator.style.top = `${y}px`;
  }

  function hideLinkHover() {
    linkHoverIndicator.style.display = 'none';
  }

  function isDocumentVisible() {
    if (typeof document.visibilityState === 'string') {
      return document.visibilityState === 'visible';
    }
    if (typeof document.hidden === 'boolean') {
      return !document.hidden;
    }
    return true;
  }

  function ensureCrossWindowWindowId() {
    if (window.creativesCrossWindowId) return window.creativesCrossWindowId;
    let identifier;
    try {
      identifier = sessionStorage.getItem('creatives.windowId');
      if (!identifier) {
        identifier = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
        sessionStorage.setItem('creatives.windowId', identifier);
      }
    } catch (error) {
      identifier = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    }
    window.creativesCrossWindowId = identifier;
    return identifier;
  }

  function createSharedDragPayload(state) {
    if (!state || !state.creativeId) return null;
    return {
      creativeId: state.creativeId,
      parentId: state.parentId || null,
      level: state.level || 1,
      isRoot: !!state.isRoot,
      treeId: state.treeId || null,
      timestamp: Date.now(),
      sourceWindowId: crossWindowWindowId
    };
  }

  function persistCrossWindowDragPayload(payload) {
    try {
      localStorage.setItem(crossWindowDragStorageKey, payload);
    } catch (error) {
      console.warn('Failed to persist drag payload for cross-window drop', error);
    }
  }

  function clearPersistedDragState() {
    try {
      localStorage.removeItem(crossWindowDragStorageKey);
    } catch (error) {
      // ignore storage failures
    }
  }

  function readDragPayloadFromStorage() {
    try {
      const stored = localStorage.getItem(crossWindowDragStorageKey);
      if (!stored) return null;
      const payload = JSON.parse(stored);
      if (payload.timestamp && Date.now() - payload.timestamp > crossWindowPayloadTTL) {
        localStorage.removeItem(crossWindowDragStorageKey);
        return null;
      }
      return payload;
    } catch (error) {
      console.warn('Failed to read drag payload from storage', error);
      return null;
    }
  }

  function readDragPayloadFromEvent(event) {
    const transfer = event && event.dataTransfer;
    if (!transfer) return null;
    try {
      const json = transfer.getData('application/json');
      if (json) {
        const payload = JSON.parse(json);
        if (payload.creativeId) return payload;
      }
    } catch (error) {
      // ignore parse errors
    }

    try {
      const text = transfer.getData('text/plain');
      if (text && text.startsWith('creative:')) {
        const creativeId = text.replace('creative:', '').trim();
        if (creativeId) {
          return {
            creativeId,
            timestamp: Date.now()
          };
        }
      }
    } catch (error) {
      // ignore
    }

    return null;
  }

  function getExternalDragPayload(event) {
    const fromEvent = readDragPayloadFromEvent(event);
    if (fromEvent && fromEvent.creativeId) return fromEvent;
    return readDragPayloadFromStorage();
  }

  function broadcastCrossWindowUpdate(action) {
    try {
      const payload = JSON.stringify({
        action,
        timestamp: Date.now(),
        sourceWindowId: crossWindowWindowId
      });
      localStorage.setItem(crossWindowDropStorageKey, payload);
    } catch (error) {
      console.warn('Failed to broadcast cross-window update', error);
    }
  }

  function performReload() {
    if (window.Turbo && typeof window.Turbo.visit === 'function') {
      window.Turbo.visit(window.location.href, { action: 'replace' });
    } else {
      window.location.reload();
    }
  }

  function scheduleCrossWindowReload() {
    if (isDocumentVisible()) {
      pendingCrossWindowReload = false;
      performReload();
    } else {
      pendingCrossWindowReload = true;
    }
  }

  window.addEventListener('focus', () => {
    if (!pendingCrossWindowReload) return;
    pendingCrossWindowReload = false;
    performReload();
  });

  document.addEventListener('visibilitychange', () => {
    if (!pendingCrossWindowReload || !isDocumentVisible()) return;
    pendingCrossWindowReload = false;
    performReload();
  });

  window.addEventListener('storage', (event) => {
    if (event.key !== crossWindowDropStorageKey || !event.newValue) return;
    try {
      const payload = JSON.parse(event.newValue);
      if (!payload || payload.sourceWindowId === crossWindowWindowId) return;
      if (payload.timestamp && Date.now() - payload.timestamp > crossWindowPayloadTTL) return;
      scheduleCrossWindowReload();
    } catch (error) {
      console.warn('Failed to handle cross-window update payload', error);
    }
  });

  function clearDragHighlight(tree) {
    if (!tree) return;
    tree.classList.remove(
      'drag-over',
      'drag-over-top',
      'drag-over-bottom',
      'drag-over-child',
      'child-drop-indicator-active'
    );
  }

  function asTreeRow(node) {
    return node ? node.closest('creative-tree-row') : null;
  }

  function getChildrenContainer(row) {
    if (!row) return null;
    const creativeId = row.getAttribute('creative-id');
    if (!creativeId) return null;
    return document.getElementById(`creative-children-${creativeId}`);
  }

  function ensureChildrenContainer(row) {
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

  function moveBlockBefore(draggedRow, draggedChildren, referenceRow) {
    const parent = referenceRow.parentNode;
    parent.insertBefore(draggedRow, referenceRow);
    if (draggedChildren) parent.insertBefore(draggedChildren, referenceRow);
  }

  function moveBlockAfter(draggedRow, draggedChildren, referenceRow) {
    const parent = referenceRow.parentNode;
    const afterNode = getNodeAfterBlock(referenceRow);
    parent.insertBefore(draggedRow, afterNode);
    if (draggedChildren) parent.insertBefore(draggedChildren, afterNode);
  }

  function appendBlockToContainer(draggedRow, draggedChildren, container) {
    container.appendChild(draggedRow);
    if (draggedChildren) container.appendChild(draggedChildren);
  }

  function isDescendantRow(parentRow, candidateRow) {
    const container = getChildrenContainer(parentRow);
    if (!container) return false;
    return container.contains(candidateRow);
  }

  function updateRowLevel(row, delta) {
    const current = Number(row.getAttribute('level') || row.level || 1);
    const next = Math.max(1, current + delta);
    if (row.level !== next) row.level = next;
    row.setAttribute('level', next);
    const tree = row.querySelector('.creative-tree');
    if (tree) tree.dataset.level = String(next);
    row.requestUpdate?.();
  }

  function applyLevelDelta(row, delta) {
    if (!row || delta === 0) return;
    updateRowLevel(row, delta);
    const childrenContainer = getChildrenContainer(row);
    if (!childrenContainer) return;
    const childRows = childrenContainer.querySelectorAll(':scope > creative-tree-row');
    childRows.forEach((childRow) => applyLevelDelta(childRow, delta));
  }

  function setRowParent(row, parentId) {
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

  function setRowRootState(row, isRoot) {
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

  function setHasChildren(row, hasChildren) {
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

  function setExpanded(row, expanded, container) {
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

  function syncParentHasChildren(parentId) {
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

  function createMoveContext({ draggedRow, draggedChildren, targetRow, targetContainerBefore }) {
    return {
      draggedRow,
      draggedChildren,
      originalParentContainer: draggedRow.parentNode,
      originalNextSibling: draggedChildren ? draggedChildren.nextSibling : draggedRow.nextSibling,
      originalParentId: draggedState.parentId,
      originalLevel: draggedState.level,
      originalIsRoot: draggedState.isRoot,
      targetRow,
      targetContainerBefore,
      targetHadContainer: !!targetContainerBefore,
      targetPreviousExpanded: targetRow ? targetRow.hasAttribute('expanded') : false,
      targetPreviousHasChildren: targetRow ? targetRow.hasAttribute('has-children') : false
    };
  }

  function revertMove(context, attemptedParentId) {
    const {
      draggedRow,
      draggedChildren,
      originalParentContainer,
      originalNextSibling,
      originalParentId,
      originalLevel,
      originalIsRoot,
      targetRow,
      targetHadContainer,
      targetPreviousExpanded,
      targetPreviousHasChildren,
      targetContainerCreated
    } = context;

    if (originalNextSibling) {
      originalParentContainer.insertBefore(draggedRow, originalNextSibling);
      if (draggedChildren) originalParentContainer.insertBefore(draggedChildren, originalNextSibling);
    } else {
      originalParentContainer.appendChild(draggedRow);
      if (draggedChildren) originalParentContainer.appendChild(draggedChildren);
    }

    const currentLevel = Number(draggedRow.getAttribute('level') || draggedRow.level || 1);
    const delta = originalLevel - currentLevel;
    if (delta !== 0) applyLevelDelta(draggedRow, delta);

    setRowParent(draggedRow, originalParentId);
    setRowRootState(draggedRow, originalIsRoot);

    if (targetRow) {
      if (targetContainerCreated) {
        const container = getChildrenContainer(targetRow);
        if (container) container.remove();
      }
      setHasChildren(targetRow, targetPreviousHasChildren);
      const targetContainer = getChildrenContainer(targetRow);
      setExpanded(targetRow, targetPreviousExpanded, targetContainer);
    }

    syncParentHasChildren(originalParentId);
    syncParentHasChildren(attemptedParentId);
  }

  function resetDragState() {
    if (lastDragOverRow) {
      clearDragHighlight(lastDragOverRow);
    }
    draggedState = null;
    lastDragOverRow = null;
    hideLinkHover();
    clearPersistedDragState();
  }

  window.handleDragStart = function(event) {
    const tree = event.target.closest(draggableClassName);
    if (!tree || tree.draggable === false) return;
    const row = asTreeRow(tree);
    if (!row) return;
    const creativeId = row.getAttribute('creative-id');
    draggedState = {
      tree,
      row,
      treeId: tree.id,
      creativeId,
      parentId: row.getAttribute('parent-id') || null,
      level: Number(row.getAttribute('level') || row.level || 1),
      isRoot: row.hasAttribute('is-root')
    };
    const sharedPayload = createSharedDragPayload(draggedState);
    if (sharedPayload) {
      const payloadJson = JSON.stringify(sharedPayload);
      try {
        event.dataTransfer.setData('application/json', payloadJson);
      } catch (error) {
        // ignore data transfer failures
      }
      try {
        event.dataTransfer.setData('text/plain', `creative:${sharedPayload.creativeId}`);
      } catch (error) {
        // ignore data transfer failures
      }
      persistCrossWindowDragPayload(payloadJson);
    } else {
      clearPersistedDragState();
    }
    event.dataTransfer.effectAllowed = 'move';
  };

  window.handleDragOver = function(event) {
    const tree = event.target.closest(draggableClassName);
    if (lastDragOverRow && lastDragOverRow !== tree) {
      clearDragHighlight(lastDragOverRow);
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

    lastDragOverRow = tree;
  };

  window.handleDrop = function(event) {
    const targetTree = event.target.closest(draggableClassName);
    const targetId = targetTree ? targetTree.id : '';
    clearDragHighlight(targetTree);
    clearDragHighlight(lastDragOverRow);

    if (!targetTree || targetTree.draggable === false) {
      resetDragState();
      hideLinkHover();
      return;
    }

    event.preventDefault();

    const targetRow = asTreeRow(targetTree);
    if (!targetRow) {
      resetDragState();
      hideLinkHover();
      return;
    }

    if (draggedState) {
      handleLocalDrop(event, targetTree, targetRow, targetId);
    } else {
      handleCrossWindowDrop(event, targetTree, targetRow, targetId);
    }
  };

  function handleLocalDrop(event, targetTree, targetRow, targetId) {
    if (!targetId || draggedState.treeId === targetId) {
      resetDragState();
      hideLinkHover();
      return;
    }

    const draggedRow = draggedState.row;
    const draggedTree = draggedState.tree;
    if (!draggedRow || !draggedTree) {
      resetDragState();
      hideLinkHover();
      return;
    }

    if (isDescendantRow(draggedRow, targetRow)) {
      resetDragState();
      hideLinkHover();
      return;
    }

    const direction = determineDropDirection(event, targetTree);

    if (event.shiftKey) {
      const stateSnapshot = draggedState;
      resetDragState();
      if (!stateSnapshot) return;

      const draggedId = stateSnapshot.creativeId;
      const targetNumericId = targetId.replace('creative-', '');

      sendLinkedCreative(draggedId, targetNumericId, direction)
        .then(() => window.location.reload())
        .catch((error) => {
          console.error('Failed to create linked creative', error);
        });

      hideLinkHover();
      return;
    }

    const draggedChildren = getChildrenContainer(draggedRow);
    const preExistingTargetContainer = direction === 'child' ? getChildrenContainer(targetRow) : null;
    const moveContext = createMoveContext({
      draggedRow,
      draggedChildren,
      targetRow,
      targetContainerBefore: preExistingTargetContainer
    });

    const targetLevel = Number(targetRow.getAttribute('level') || targetRow.level || 1);
    let newParentId;
    let newLevel;
    let targetContainer = preExistingTargetContainer;

    if (direction === 'child') {
      targetContainer = targetContainer || ensureChildrenContainer(targetRow);
      moveContext.targetContainerCreated = !moveContext.targetHadContainer && !!targetContainer;
      newParentId = targetRow.getAttribute('creative-id');
      newLevel = targetLevel + 1;
      appendBlockToContainer(draggedRow, draggedChildren, targetContainer);
      setHasChildren(targetRow, true);
      setExpanded(targetRow, true, targetContainer);
    } else if (direction === 'up') {
      newParentId = targetRow.getAttribute('parent-id') || null;
      newLevel = targetLevel;
      moveBlockBefore(draggedRow, draggedChildren, targetRow);
    } else {
      newParentId = targetRow.getAttribute('parent-id') || null;
      newLevel = targetLevel;
      moveBlockAfter(draggedRow, draggedChildren, targetRow);
    }

    const levelDelta = newLevel - draggedState.level;
    if (levelDelta !== 0) applyLevelDelta(draggedRow, levelDelta);

    setRowParent(draggedRow, newParentId);
    setRowRootState(draggedRow, !newParentId);

    syncParentHasChildren(draggedState.parentId);
    syncParentHasChildren(newParentId);

    const draggedNumericId = draggedState.creativeId;

    sendNewOrder(
      draggedNumericId,
      targetId.replace('creative-', ''),
      direction,
      function revert() {
        revertMove(moveContext, newParentId);
      }
    );

    resetDragState();
  }

  function handleCrossWindowDrop(event, targetTree, targetRow, targetId) {
    const sharedState = getExternalDragPayload(event);
    const targetNumericId = targetId ? targetId.replace('creative-', '') : '';

    if (!sharedState || !sharedState.creativeId || !targetNumericId) {
      resetDragState();
      hideLinkHover();
      return;
    }

    if (sharedState.treeId && sharedState.treeId === targetId) {
      resetDragState();
      hideLinkHover();
      return;
    }

    if (String(sharedState.creativeId) === targetNumericId) {
      resetDragState();
      hideLinkHover();
      return;
    }

    const draggedRowLocal = document.querySelector(
      `creative-tree-row[creative-id="${sharedState.creativeId}"]`
    );
    if (draggedRowLocal && isDescendantRow(draggedRowLocal, targetRow)) {
      resetDragState();
      hideLinkHover();
      return;
    }

    const direction = determineDropDirection(event, targetTree);
    const draggedNumericId = sharedState.creativeId;

    if (event.shiftKey) {
      sendLinkedCreative(draggedNumericId, targetNumericId, direction)
        .then(() => {
          finalizeCrossWindowDrop('link');
        })
        .catch((error) => {
          console.error('Failed to create linked creative', error);
          resetDragState();
        });
      return;
    }

    sendNewOrder(draggedNumericId, targetNumericId, direction, null).then((response) => {
      if (response && response.ok) {
        finalizeCrossWindowDrop('reorder');
      } else {
        resetDragState();
      }
    });
  }

  function determineDropDirection(event, targetTree) {
    const rect = targetTree.getBoundingClientRect();
    const topZone = relaxedCoord(rect.top + rect.height * childZoneRatio);
    const bottomZone = relaxedCoord(rect.bottom - rect.height * childZoneRatio);
    const y = relaxedCoord(event.clientY);

    if (y >= topZone && y <= bottomZone) {
      return 'child';
    }
    if (y < topZone) {
      return 'up';
    }
    return 'down';
  }

  function finalizeCrossWindowDrop(action) {
    resetDragState();
    broadcastCrossWindowUpdate(action);
    scheduleCrossWindowReload();
  }

  window.handleDragLeave = function(event) {
    const tree = event.target.closest(draggableClassName);
    if (!tree || tree.draggable === false) return;
    clearDragHighlight(tree);
    hideLinkHover();
  };

  function sendNewOrder(draggedId, targetId, direction, onErrorRevert) {
    return fetch('/creatives/reorder', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
      },
      body: JSON.stringify({ dragged_id: draggedId, target_id: targetId, direction: direction })
    })
    .then(response => {
      if (!response.ok) {
        console.error('Failed to update order');
        if (onErrorRevert) onErrorRevert();
        return null;
      }
      return response;
    })
    .catch((error) => {
      console.error('Failed to update order', error);
      if (onErrorRevert) onErrorRevert();
      return null;
    });
  }

  function sendLinkedCreative(draggedId, targetId, direction) {
    return fetch('/creatives/link_drop', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
      },
      body: JSON.stringify({ dragged_id: draggedId, target_id: targetId, direction: direction })
    })
      .then(response => {
        if (!response.ok) throw new Error('Failed to create linked creative');
        return response.json();
      });
  }

  document.addEventListener('dragend', () => {
    resetDragState();
  });
}
