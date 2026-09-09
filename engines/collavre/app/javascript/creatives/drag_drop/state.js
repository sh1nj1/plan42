const state = {
  dragged: null,
  lastOverRow: null,
  lastOverPosition: null,
};

export function setDraggedState(payload) {
  state.dragged = payload;
}

export function getDraggedState() {
  return state.dragged;
}

export function resetDraggedState() {
  state.dragged = null;
  state.lastOverRow = null;
  state.lastOverPosition = null;
}

export function setLastDragOverRow(row, position = null) {
  state.lastOverRow = row;
  state.lastOverPosition = position;
}

export function getLastDragOverRow() {
  return state.lastOverRow;
}

export function getLastDragOverPosition() {
  return state.lastOverPosition;
}

export function hasDraggedState() {
  return !!state.dragged;
}

export default state;
