/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';

const sendNewOrder = jest.fn();
const sendLinkedCreative = jest.fn();
const alertDialog = jest.fn();
jest.unstable_mockModule('../../../lib/api/drag_drop', () => ({
  sendNewOrder,
  sendLinkedCreative,
  sendTopicMove: jest.fn(),
  isAuthenticationRedirect: response => response?.redirected === true,
}));
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog }));
const { handleDragOver, handleDragLeave, handleDragStart, handleDrop } = await import('../event_handlers');
const { resetDraggedState, getLastDragOverPosition } = await import('../state');
const { writeDragData } = await import('../../../lib/dnd/envelope');
const { resetDragSessionCache } = await import('../../../lib/dnd/session');

function transfer() {
  const values = new Map();
  return {
    get types() { return [...values.keys()]; },
    setData: (key, value) => values.set(key, value),
    getData: key => values.get(key) || '',
  };
}

function event(target, dataTransfer, clientY = 150) {
  return { target, dataTransfer, clientY, clientX: 0, shiftKey: false, preventDefault: jest.fn() };
}

beforeEach(() => {
  jest.clearAllMocks();
  jest.spyOn(console, 'error').mockImplementation(() => {});
  resetDraggedState();
  resetDragSessionCache();
  localStorage.clear();
  sessionStorage.clear();
  document.body.innerHTML = '<div id="creatives">' + ['1', '9'].map(id => `
    <creative-tree-row creative-id="${id}" level="1">
      <div class="creative-tree" id="creative-${id}" draggable="true"></div>
    </creative-tree-row>`).join('') + '</div>';
  document.querySelectorAll('.creative-tree').forEach(tree => {
    tree.getBoundingClientRect = () => ({ top: 100, height: 100 });
  });
  sendNewOrder.mockResolvedValue({ ok: false, status: 403 });
});

afterEach(() => {
  resetDraggedState();
  resetDragSessionCache();
  document.body.innerHTML = '';
  jest.restoreAllMocks();
});

test('cross-window canonical IDs reach the batch command without duplicate payload IDs', async () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['2', '3'], payload: { creativeId: '2', treeId: 'creative-2' } });
  const result = await handleDrop(event(document.getElementById('creative-9'), dataTransfer));
  expect(sendNewOrder).toHaveBeenCalledWith({ draggedIds: ['2', '3'], targetId: '9', direction: 'child' });
  expect(result.status).toBe('failure');
  expect(result.failedIds).toEqual(['2', '3']);
});

test('canonical IDs override stale payload selection and supply the active ID', async () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['2', '3'], payload: { treeId: 'creative-2', selectedCreativeIds: ['7'] } });
  await handleDrop(event(document.getElementById('creative-9'), dataTransfer));
  expect(sendNewOrder).toHaveBeenCalledWith({ draggedIds: ['2', '3'], targetId: '9', direction: 'child' });
});

test('drop direction follows intent even if presentation classes are replaced', async () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['2'], payload: { treeId: 'creative-2' } });
  const target = document.getElementById('creative-9');
  handleDragOver(event(target, dataTransfer, 101));
  target.classList.remove('drag-over-top');
  target.classList.add('drag-over-bottom');
  await handleDrop(event(target, dataTransfer, 199));
  expect(sendNewOrder).toHaveBeenCalledWith({ draggedId: '2', targetId: '9', direction: 'up' });
  expect(getLastDragOverPosition()).toBeNull();
});

test('hysteresis follows state and leave discards the previous intent', () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['2'], payload: { treeId: 'creative-2' } });
  const target = document.getElementById('creative-9');
  handleDragOver(event(target, dataTransfer, 101));
  target.classList.remove('drag-over-top');
  handleDragOver(event(target, dataTransfer, 140));
  expect(getLastDragOverPosition()).toBe('up');
  handleDragLeave(event(target, dataTransfer));
  expect(getLastDragOverPosition()).toBeNull();
  handleDragOver(event(target, dataTransfer, 140));
  expect(getLastDragOverPosition()).toBe('child');
});

test.each([
  ['permission failure', { ok: false, status: 403 }],
  ['authentication redirect', { ok: true, redirected: true, status: 200 }],
])('local optimistic move is restored after %s', async (_label, response) => {
  const dataTransfer = transfer();
  const source = document.getElementById('creative-1');
  const target = document.getElementById('creative-9');
  sendNewOrder.mockResolvedValue(response);
  handleDragStart(event(source, dataTransfer));
  const running = handleDrop(event(target, dataTransfer));
  expect(source.closest('creative-tree-row').getAttribute('parent-id')).toBe('9');
  const result = await running;
  expect(result.status).toBe('failure');
  expect(source.closest('creative-tree-row').parentElement.id).toBe('creatives');
  expect(source.closest('creative-tree-row').getAttribute('parent-id')).toBeFalsy();
});

test('Shift bundle uses the ordered link command and reports all failures', async () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['2', '3'], payload: { treeId: 'creative-2' } });
  sendLinkedCreative.mockRejectedValue(new Error('offline'));
  const drop = event(document.getElementById('creative-9'), dataTransfer, 199);
  drop.shiftKey = true;
  const result = await handleDrop(drop);
  expect(sendLinkedCreative.mock.calls.map(([call]) => call.draggedId)).toEqual(['3', '2']);
  expect(sendNewOrder).not.toHaveBeenCalled();
  expect(result.failedIds).toEqual(['2', '3']);
});

test('tampered session data never reaches the move command', async () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['2'], payload: { treeId: 'creative-2' } });
  for (const type of dataTransfer.types) {
    const data = JSON.parse(dataTransfer.getData(type));
    data.token = 'untrusted';
    dataTransfer.setData(type, JSON.stringify(data));
  }
  await handleDrop(event(document.getElementById('creative-9'), dataTransfer));
  expect(sendNewOrder).not.toHaveBeenCalled();
  expect(alertDialog).toHaveBeenCalled();
});

test('a successful local move keeps the optimistic row and emits completion', async () => {
  const dataTransfer = transfer();
  const source = document.getElementById('creative-1');
  const completed = jest.fn();
  window.addEventListener('collavre:creative-drop-complete', completed);
  try {
    sendNewOrder.mockResolvedValue({ ok: true, status: 200 });
    handleDragStart(event(source, dataTransfer));
    const result = await handleDrop(event(document.getElementById('creative-9'), dataTransfer));
    expect(result.status).toBe('success');
    expect(source.closest('creative-tree-row').getAttribute('parent-id')).toBe('9');
    expect(completed).toHaveBeenCalledTimes(1);
    expect(completed.mock.calls[0][0].detail).toMatchObject({ creativeId: '1', context: 'target' });
  } finally {
    window.removeEventListener('collavre:creative-drop-complete', completed);
  }
});

test('a single canonical ID cannot drop onto itself with a different tree ID', async () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['9'], payload: { treeId: 'workspace-9' } });
  await handleDrop(event(document.getElementById('creative-9'), dataTransfer));
  expect(sendNewOrder).not.toHaveBeenCalled();
  expect(sendLinkedCreative).not.toHaveBeenCalled();
});

test('invalid target geometry does not retain an actionable preview', () => {
  const dataTransfer = transfer();
  writeDragData(dataTransfer, { kind: 'creative', ids: ['2'], payload: { treeId: 'creative-2' } });
  const target = document.getElementById('creative-9');
  handleDragOver(event(target, dataTransfer, 101));
  target.getBoundingClientRect = () => ({ top: 100, height: 0 });
  handleDragOver(event(target, dataTransfer));
  expect(getLastDragOverPosition()).toBeNull();
  expect(target.classList.contains('drag-over')).toBe(false);
});
