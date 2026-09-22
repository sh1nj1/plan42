import {
  getDraggedState,
  getLastDragOverPosition,
  getLastDragOverRow,
  hasDraggedState,
  resetDraggedState,
  setDraggedState,
  setLastDragOverRow,
} from '../state';

afterEach(() => resetDraggedState());

test('stores drag payload and drop intent independently', () => {
  const dragged = { creativeId: '7' };
  const row = {};

  setDraggedState(dragged);
  setLastDragOverRow(row, 'child');

  expect(getDraggedState()).toBe(dragged);
  expect(hasDraggedState()).toBe(true);
  expect(getLastDragOverRow()).toBe(row);
  expect(getLastDragOverPosition()).toBe('child');
});

test('clears the row position by default and resets all drag state', () => {
  setDraggedState({ creativeId: '7' });
  setLastDragOverRow({}, 'up');
  setLastDragOverRow(null);

  expect(getLastDragOverPosition()).toBeNull();
  resetDraggedState();
  expect(getDraggedState()).toBeNull();
  expect(getLastDragOverRow()).toBeNull();
  expect(hasDraggedState()).toBe(false);
});
