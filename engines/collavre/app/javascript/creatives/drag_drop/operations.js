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
import { MOVE_STATUSES, executeMoveCommand } from './move_command';

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

/**
 * Right-hand tree adapter: run a move command with optimistic-DOM recovery.
 *
 * The creative tree moves the row the instant the pointer is released, so the
 * DOM is ahead of the server for the length of one request. Anything short of
 * an outright success has to be undone — a `partial` link result included,
 * since a half-applied move on screen is a lie either way.
 *
 * Recovery lives here, not in `move_command.js`: the command is DOM-free by
 * contract so the left workspace tree and the keyboard move menu can reuse it
 * with their own (or no) repaint strategy. Pass `moveContext: null` when there
 * was no optimistic move to undo and this becomes a plain command runner.
 *
 * @param {object} options
 * @param {object} options.command move command (or plain intent) to execute
 * @param {object|null} [options.moveContext] context from {@link createMoveContext}
 * @param {string|null} [options.attemptedParentId] parent the row was moved into
 * @param {Function} [options.execute] command runner, injectable for tests
 * @param {object} [options.api] API overrides forwarded to the command runner
 * @returns {Promise<object>} the move result; rejects only for an invalid command
 */
export function runMoveWithDomRecovery({
  command,
  moveContext = null,
  attemptedParentId = null,
  execute = executeMoveCommand,
  api,
} = {}) {
  const recoverDom = () => {
    if (moveContext) revertMove(moveContext, attemptedParentId);
  };

  let running;
  try {
    running = Promise.resolve(execute(command, { api }));
  } catch (error) {
    // A synchronous throw from a non-async `execute` still leaves the row in
    // the wrong place.
    recoverDom();
    return Promise.reject(error);
  }

  return running.then(
    (result) => {
      if (!result || result.status !== MOVE_STATUSES.SUCCESS) recoverDom();
      return result;
    },
    (error) => {
      recoverDom();
      throw error;
    }
  );
}
