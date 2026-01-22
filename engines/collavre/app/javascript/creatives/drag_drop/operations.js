import {
  getChildrenContainer,
  ensureChildrenContainer,
  appendBlockToContainer,
  moveBlockBefore,
  moveBlockAfter,
  setRowParent,
  setRowRootState,
  applyLevelDelta,
  setHasChildren,
  setExpanded,
  syncParentHasChildren,
} from './dom';

export function createMoveContext(draggedState, targetRow, draggedChildren) {
  return {
    draggedRow: draggedState.row,
    draggedChildren,
    originalParentContainer: draggedState.row.parentNode,
    originalNextSibling: draggedChildren ? draggedChildren.nextSibling : draggedState.row.nextSibling,
    originalParentId: draggedState.parentId,
    originalLevel: draggedState.level,
    originalIsRoot: draggedState.isRoot,
    targetRow,
    targetHadContainer: !!getChildrenContainer(targetRow),
    targetPreviousExpanded: targetRow ? targetRow.hasAttribute('expanded') : false,
    targetPreviousHasChildren: targetRow ? targetRow.hasAttribute('has-children') : false,
  };
}

export function applyMove({
  direction,
  targetRow,
  draggedState,
  draggedChildren,
  moveContext,
}) {
  const targetLevel = Number(targetRow.getAttribute('level') || targetRow.level || 1);
  let newParentId;
  let newLevel;
  let targetContainer = direction === 'child' ? getChildrenContainer(targetRow) : null;

  if (direction === 'child') {
    targetContainer = targetContainer || ensureChildrenContainer(targetRow);
    moveContext.targetContainerCreated = !moveContext.targetHadContainer && !!targetContainer;
    newParentId = targetRow.getAttribute('creative-id');
    newLevel = targetLevel + 1;
    appendBlockToContainer(draggedState.row, draggedChildren, targetContainer);
    setHasChildren(targetRow, true);
    setExpanded(targetRow, true, targetContainer);
  } else if (direction === 'up') {
    newParentId = targetRow.getAttribute('parent-id') || null;
    newLevel = targetLevel;
    moveBlockBefore(draggedState.row, draggedChildren, targetRow);
  } else {
    newParentId = targetRow.getAttribute('parent-id') || null;
    newLevel = targetLevel;
    moveBlockAfter(draggedState.row, draggedChildren, targetRow);
  }

  const levelDelta = newLevel - draggedState.level;
  if (levelDelta !== 0) applyLevelDelta(draggedState.row, levelDelta);

  setRowParent(draggedState.row, newParentId);
  setRowRootState(draggedState.row, !newParentId);

  syncParentHasChildren(draggedState.parentId);
  syncParentHasChildren(newParentId);

  return { newParentId, newLevel };
}

export function revertMove(context, attemptedParentId) {
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
    targetContainerCreated,
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
