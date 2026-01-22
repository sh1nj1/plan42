const state = {
  dragged: null,
  lastOverRow: null,
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
}

export function setLastDragOverRow(row) {
  state.lastOverRow = row;
}

export function getLastDragOverRow() {
  return state.lastOverRow;
}

export function hasDraggedState() {
  return !!state.dragged;
}

export default state;
