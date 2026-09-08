/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';
import { handleDragOver } from '../event_handlers';
import { resetDraggedState } from '../state';

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

  const outsideChildHysteresis = dragEvent(
    target,
    ['application/x-collavre-creative'],
    117.9
  );
  handleDragOver(outsideChildHysteresis);
  expect(tree.classList.contains('drag-over-top')).toBe(true);
});

test('keeps topic moves as child drops', () => {
  const { tree, target } = mountTarget();
  const event = dragEvent(target, ['application/x-topic-move'], 101);

  handleDragOver(event);

  expect(event.preventDefault).toHaveBeenCalled();
  expect(tree.classList.contains('drag-over-child')).toBe(true);
});
