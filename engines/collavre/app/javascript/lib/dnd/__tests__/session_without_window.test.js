/** @jest-environment node */
import { test, expect } from '@jest/globals';
import {
  readDragSessionToken, ensureDragSessionToken, readDragWindowId,
  ensureDragWindowId, emitDropSignal, dispatchDropCompletion,
} from '../session';

test('importing the shared session without a browser cannot create or emit a drag', () => {
  expect(readDragSessionToken()).toBeNull();
  expect(ensureDragSessionToken()).toBeNull();
  expect(readDragWindowId()).toBeNull();
  expect(ensureDragWindowId()).toBeNull();
  expect(emitDropSignal({ creativeId: '7' })).toBe(false);
  expect(dispatchDropCompletion({ creativeId: '7' })).toBe(false);
});
