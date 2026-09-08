/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';
import { handleDragOver, handleDrop } from '../event_handlers';
import {
  getLastDragOverPosition,
  resetDraggedState,
  setDraggedState,
  setLastDragOverRow,
} from '../state';
import { writeDragData } from '../../../lib/dnd/envelope';

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
  resetDraggedState();
  document.body.innerHTML = '';
  jest.restoreAllMocks();
});

test('uses MIME types to ignore unsupported drags during dragover', () => {
  const { tree, target } = mountTarget();
  const event = dragEvent(target, ['Files']);

  handleDragOver(event);

  expect(event.preventDefault).not.toHaveBeenCalled();
  expect(tree.classList.contains('drag-over')).toBe(false);
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

test('drops with the stored intent without reading preview CSS classes', async () => {
  document.body.innerHTML = `
    <div id="creatives">
      <creative-tree-row creative-id="1" level="1" is-root>
        <div class="creative-tree" id="creative-1" draggable="true"></div>
      </creative-tree-row>
      <creative-tree-row creative-id="2" level="1" is-root>
        <div class="creative-tree" id="creative-2" draggable="true">
          <span id="drop-target"></span>
        </div>
      </creative-tree-row>
    </div>
  `;
  const sourceTree = document.getElementById('creative-1');
  const sourceRow = sourceTree.closest('creative-tree-row');
  const targetTree = document.getElementById('creative-2');
  const transfer = new Map();
  const dataTransfer = {
    types: [],
    setData(type, value) {
      transfer.set(type, value);
      this.types = [...transfer.keys()];
    },
    getData: (type) => transfer.get(type) || '',
  };
  writeDragData(dataTransfer, {
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
    dataTransfer,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  const options = fetchMock.mock.calls[0][1];
  expect(JSON.parse(options.body)).toMatchObject({
    dragged_id: '1',
    target_id: '2',
    direction: 'up',
  });
  delete globalThis.fetch;
});
