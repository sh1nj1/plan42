/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';
import {
  addGlobalListeners,
  handleDragLeave,
  handleDragOver,
  handleDragStart,
  handleDrop,
  removeGlobalListeners,
} from '../event_handlers';
import {
  getDraggedState,
  getLastDragOverPosition,
  resetDraggedState,
  setDraggedState,
  setLastDragOverRow,
} from '../state';
import { LEGACY_MIME_TYPES, writeDragData } from '../../../lib/dnd/envelope';

function dataTransfer() {
  const transfer = new Map();
  return {
    types: [],
    effectAllowed: 'none',
    dropEffect: 'none',
    setDragImage: jest.fn(),
    setData(type, value) {
      transfer.set(type, value);
      this.types = [...transfer.keys()];
    },
    getData: (type) => transfer.get(type) || '',
  };
}

function mountTarget() {
  document.body.innerHTML = `
    <creative-tree-row creative-id="7">
      <div class="creative-tree" id="creative-7" draggable="true">
        <span id="target"></span>
      </div>
    </creative-tree-row>
  `;
  const tree = document.getElementById('creative-7');
  tree.getBoundingClientRect = () => ({ top: 100, height: 100 });
  return { tree, target: document.getElementById('target') };
}

function dragEvent(target, types, clientY = 150) {
  return {
    target,
    clientY,
    clientX: 0,
    shiftKey: false,
    preventDefault: jest.fn(),
    dataTransfer: { types, dropEffect: 'none' },
  };
}

afterEach(() => {
  removeGlobalListeners();
  resetDraggedState();
  document.body.innerHTML = '';
  delete globalThis.fetch;
  jest.restoreAllMocks();
});

test('uses MIME types to ignore unsupported drags during dragover', () => {
  const { tree, target } = mountTarget();
  const event = dragEvent(target, ['Files']);

  handleDragOver(event);

  expect(event.preventDefault).not.toHaveBeenCalled();
  expect(tree.classList.contains('drag-over')).toBe(false);
});

test('clears the previous target and intent when dragover changes rows', () => {
  const { target } = mountTarget();
  const previous = document.createElement('div');
  previous.className = 'drag-over drag-over-top';
  setLastDragOverRow(previous, 'up');

  handleDragOver(dragEvent(target, ['Files']));

  expect(previous.classList.contains('drag-over')).toBe(false);
  expect(getLastDragOverPosition()).toBeNull();
});

test('uses the shared boundary and hysteresis result for creative drags', () => {
  const { tree, target } = mountTarget();
  const boundary = dragEvent(target, ['application/x-collavre-creative'], 130);

  handleDragOver(boundary);
  expect(boundary.preventDefault).toHaveBeenCalled();
  expect(boundary.dataTransfer.dropEffect).toBe('move');
  expect(tree.classList.contains('drag-over-child')).toBe(true);
  expect(getLastDragOverPosition()).toBe('child');

  const outsideChildHysteresis = dragEvent(
    target,
    ['application/x-collavre-creative'],
    117.9
  );
  handleDragOver(outsideChildHysteresis);
  expect(tree.classList.contains('drag-over-top')).toBe(true);
  expect(getLastDragOverPosition()).toBe('up');
});

test('keeps topic moves as child drops', () => {
  const { tree, target } = mountTarget();
  const event = dragEvent(target, ['application/x-topic-move'], 101);

  handleDragOver(event);

  expect(event.preventDefault).toHaveBeenCalled();
  expect(tree.classList.contains('drag-over-child')).toBe(true);
});

test('starts a selected creative bundle through the shared writer', () => {
  document.body.innerHTML = `
    <input class="select-creative-checkbox" type="checkbox" value="2" checked>
    <creative-tree-row creative-id="1" level="1" is-root>
      <div class="creative-tree" id="creative-1" draggable="true">
      <span class="creative-content">First</span>
      <span id="drag-target"></span>
      </div>
    </creative-tree-row>
  `;
  const transfer = dataTransfer();

  handleDragStart({
    target: document.getElementById('drag-target'),
    dataTransfer: transfer,
  });

  expect(transfer.effectAllowed).toBe('move');
  expect(transfer.types).toContain(LEGACY_MIME_TYPES.creative);
  expect(JSON.parse(transfer.getData(LEGACY_MIME_TYPES.creative))).toMatchObject({
    creativeId: '1',
    selectedCreativeIds: ['2', '1'],
  });
  expect(getDraggedState()).toMatchObject({
    creativeId: '1',
    selectedCreativeIds: ['2', '1'],
  });
});

test('drops with the stored intent without reading preview CSS classes', async () => {
  document.body.innerHTML = `<div id="creatives">
    <creative-tree-row creative-id="1" level="1" is-root>
      <div class="creative-tree" id="creative-1" draggable="true"></div>
    </creative-tree-row>
    <creative-tree-row creative-id="2" level="1" is-root>
      <div class="creative-tree" id="creative-2" draggable="true">
      <span id="drop-target"></span>
      </div>
    </creative-tree-row>
  </div>`;
  const sourceTree = document.getElementById('creative-1');
  const sourceRow = sourceTree.closest('creative-tree-row');
  const targetTree = document.getElementById('creative-2');
  const transfer = dataTransfer();
  writeDragData(transfer, {
    kind: 'creative',
    ids: ['1'],
    payload: {
      creativeId: '1',
      treeId: 'creative-1',
      level: 1,
      isRoot: true,
    },
  });
  setDraggedState({
    tree: sourceTree,
    row: sourceRow,
    treeId: 'creative-1',
    creativeId: '1',
    parentId: null,
    level: 1,
    isRoot: true,
    selectedCreativeIds: ['1'],
  });
  setLastDragOverRow(targetTree, 'up');
  expect(targetTree.className).toBe('creative-tree');

  const fetchMock = jest.fn().mockResolvedValue({
    ok: true,
    headers: { get: () => null },
  });
  globalThis.fetch = fetchMock;
  handleDrop({
    target: document.getElementById('drop-target'),
    clientY: 150,
    shiftKey: false,
    preventDefault: jest.fn(),
    dataTransfer: transfer,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  const options = fetchMock.mock.calls[0][1];
  expect(JSON.parse(options.body)).toMatchObject({
    dragged_id: '1',
    target_id: '2',
    direction: 'up',
  });
});

test('preserves canonical ids for an external creative bundle', () => {
  document.body.innerHTML = `<creative-tree-row creative-id="9" level="1" is-root>
    <div class="creative-tree" id="creative-9" draggable="true">
      <span id="external-drop-target"></span>
    </div>
  </creative-tree-row>`;
  const targetTree = document.getElementById('creative-9');
  const transfer = dataTransfer();
  writeDragData(transfer, {
    kind: 'creative',
    ids: ['1', '2'],
    payload: {
      creativeId: '1',
      treeId: 'creative-1',
      level: 1,
      isRoot: true,
    },
  });
  setLastDragOverRow(targetTree, 'child');

  const fetchMock = jest.fn(() => new Promise(() => {}));
  globalThis.fetch = fetchMock;
  handleDrop({
    target: document.getElementById('external-drop-target'),
    clientY: 150,
    shiftKey: false,
    preventDefault: jest.fn(),
    dataTransfer: transfer,
  });

  const options = fetchMock.mock.calls[0][1];
  expect(JSON.parse(options.body)).toMatchObject({
    dragged_ids: ['1', '2'],
    target_id: '9',
    direction: 'child',
  });
});

test('falls back to hit testing when no preview intent is stored', () => {
  const { tree, target } = mountTarget();
  const transfer = dataTransfer();
  writeDragData(transfer, {
    kind: 'creative',
    ids: ['1'],
    payload: { creativeId: '1', treeId: 'creative-1' },
  });
  const fetchMock = jest.fn(() => new Promise(() => {}));
  globalThis.fetch = fetchMock;

  handleDrop({
    target,
    clientY: 101,
    shiftKey: false,
    preventDefault: jest.fn(),
    dataTransfer: transfer,
  });

  expect(JSON.parse(fetchMock.mock.calls[0][1].body).direction).toBe('up');
  expect(tree.classList.contains('drag-over')).toBe(false);
});

test('rejects a drop when fallback hit-test geometry is invalid', () => {
  const { tree, target } = mountTarget();
  tree.getBoundingClientRect = () => ({ top: 0, height: 0 });
  const transfer = dataTransfer();
  writeDragData(transfer, {
    kind: 'creative',
    ids: ['1'],
    payload: { creativeId: '1', treeId: 'creative-1' },
  });
  const fetchMock = jest.fn();
  globalThis.fetch = fetchMock;

  handleDrop({
    target,
    clientY: 0,
    shiftKey: false,
    preventDefault: jest.fn(),
    dataTransfer: transfer,
  });

  expect(fetchMock).not.toHaveBeenCalled();
});

test('clears stored intent when the active target is left', () => {
  const { tree, target } = mountTarget();
  setLastDragOverRow(tree, 'child');
  tree.classList.add('drag-over', 'drag-over-child');

  handleDragLeave({ target });

  expect(tree.classList.contains('drag-over')).toBe(false);
  expect(getLastDragOverPosition()).toBeNull();
});

test('ignores unrelated storage events through the shared signal reader', () => {
  addGlobalListeners();

  window.dispatchEvent(new StorageEvent('storage', {
    key: 'unrelated',
    newValue: '{}',
  }));

  removeGlobalListeners();
});
