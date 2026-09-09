import { jest } from '@jest/globals';
import {
  DRAG_TOKEN_STORAGE_KEY,
  DROP_COMPLETED_EVENT,
  DROP_SIGNAL_STORAGE_KEY,
  WINDOW_ID_SESSION_KEY,
  dispatchDropCompletion,
  emitDropSignal,
  ensureDragSessionToken,
  ensureDragWindowId,
  readDragSessionToken,
  readDragWindowId,
  readDropSignal,
  resetDragSessionCache,
} from '../session';

beforeEach(() => {
  window.localStorage.clear();
  window.sessionStorage.clear();
  resetDragSessionCache();
});

afterEach(() => {
  jest.restoreAllMocks();
});

test('does not create a trusted session when local storage is unavailable', () => {
  const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage');
  try {
    Object.defineProperty(window, 'localStorage', { configurable: true, value: null });
    expect(ensureDragSessionToken()).toBeNull();
  } finally {
    Object.defineProperty(window, 'localStorage', descriptor);
  }

  window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'cached');
  expect(readDragSessionToken()).toBe('cached');
  try {
    Object.defineProperty(window, 'localStorage', { configurable: true, value: null });
    expect(emitDropSignal({ creativeId: '7' })).toBe(false);
  } finally {
    Object.defineProperty(window, 'localStorage', descriptor);
  }
});

test('creates and reuses one shared token and one id per window', () => {
  const token = ensureDragSessionToken();
  const windowId = ensureDragWindowId();

  expect(token).toBeTruthy();
  expect(windowId).toBeTruthy();
  expect(window.localStorage.getItem(DRAG_TOKEN_STORAGE_KEY)).toBe(token);
  expect(window.sessionStorage.getItem(WINDOW_ID_SESSION_KEY)).toBe(windowId);
  expect(ensureDragSessionToken()).toBe(token);
  expect(ensureDragWindowId()).toBe(windowId);

  resetDragSessionCache();
  expect(readDragSessionToken()).toBe(token);
  expect(readDragWindowId()).toBe(windowId);
});

test('emits a nonce-bearing signal and validates its session and source window', () => {
  window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token');
  window.sessionStorage.setItem(WINDOW_ID_SESSION_KEY, 'source-window');
  resetDragSessionCache();

  let written;
  const originalSetItem = window.Storage.prototype.setItem;
  jest.spyOn(window.Storage.prototype, 'setItem').mockImplementation(function (key, value) {
    if (key === DROP_SIGNAL_STORAGE_KEY) written = value;
    return originalSetItem.call(this, key, value);
  });

  expect(emitDropSignal({ creativeId: '7', sourceWindowId: 'source-window' }))
    .toBe(true);
  const payload = JSON.parse(written);
  expect(payload).toMatchObject({
    creativeId: '7',
    sourceWindowId: 'source-window',
    sessionToken: 'token',
  });
  expect(payload.nonce).toBeTruthy();
  expect(window.localStorage.getItem(DROP_SIGNAL_STORAGE_KEY)).toBeNull();

  expect(readDropSignal({ key: DROP_SIGNAL_STORAGE_KEY, newValue: written }))
    .toEqual(payload);
  expect(readDropSignal({ key: 'other', newValue: written })).toBeNull();
  expect(readDropSignal({ key: DROP_SIGNAL_STORAGE_KEY, newValue: '' })).toBeNull();
  expect(readDropSignal({
    key: DROP_SIGNAL_STORAGE_KEY,
    newValue: JSON.stringify({ ...payload, sessionToken: 'wrong' }),
  })).toBeNull();
  expect(readDropSignal({
    key: DROP_SIGNAL_STORAGE_KEY,
    newValue: JSON.stringify({ ...payload, sourceWindowId: 'other-window' }),
  })).toBeNull();
});

test('rejects malformed signals and reports storage failures', () => {
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});

  expect(readDropSignal({ key: DROP_SIGNAL_STORAGE_KEY, newValue: '{bad' })).toBeNull();
  expect(readDropSignal({ key: DROP_SIGNAL_STORAGE_KEY, newValue: 'null' })).toBeNull();
  expect(error).toHaveBeenCalledWith(
    'Failed to parse drop completion payload',
    expect.any(SyntaxError)
  );

  jest.spyOn(window.Storage.prototype, 'getItem').mockImplementation(() => {
    throw new Error('blocked');
  });
  resetDragSessionCache();
  expect(readDragSessionToken()).toBeNull();
  expect(readDragWindowId()).toBeNull();
  expect(emitDropSignal({ sourceWindowId: 'x' })).toBe(false);
  error.mockRestore();
});

test('keeps a generated window id when session storage cannot persist it', () => {
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});
  jest.spyOn(window.Storage.prototype, 'setItem').mockImplementation(() => {
    throw new Error('blocked');
  });

  const windowId = ensureDragWindowId();
  expect(windowId).toBeTruthy();
  expect(readDragWindowId()).toBe(windowId);
  expect(error).toHaveBeenCalledWith(
    'Failed to persist drag window id',
    expect.any(Error)
  );
  error.mockRestore();
});

test('reports token persistence and signal broadcast failures', () => {
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});
  const setItem = jest.spyOn(window.Storage.prototype, 'setItem');
  setItem.mockImplementation(() => { throw new Error('blocked'); });

  expect(ensureDragSessionToken()).toBeNull();
  expect(error).toHaveBeenCalledWith(
    'Failed to persist drag session token',
    expect.any(Error)
  );

  setItem.mockRestore();
  window.localStorage.setItem(DRAG_TOKEN_STORAGE_KEY, 'token');
  resetDragSessionCache();
  jest.spyOn(window.Storage.prototype, 'setItem').mockImplementation(() => {
    throw new Error('blocked');
  });
  expect(emitDropSignal({ sourceWindowId: 'x' })).toBe(false);
  expect(error).toHaveBeenCalledWith(
    'Failed to broadcast drop completion signal',
    expect.any(Error)
  );
  error.mockRestore();
});

test('dispatches the shared completion event', () => {
  const listener = jest.fn();
  window.addEventListener(DROP_COMPLETED_EVENT, listener);

  expect(dispatchDropCompletion({ creativeId: '7' })).toBe(true);
  expect(listener).toHaveBeenCalledTimes(1);
  expect(listener.mock.calls[0][0].detail).toEqual({ creativeId: '7' });

  window.removeEventListener(DROP_COMPLETED_EVENT, listener);
});

test('falls back when crypto identifiers are unavailable', () => {
  const descriptor = Object.getOwnPropertyDescriptor(window, 'crypto');
  Object.defineProperty(window, 'crypto', {
    configurable: true,
    value: {},
  });

  const token = ensureDragSessionToken();
  expect(token).toMatch(/^[a-z0-9]+-[a-z0-9]+$/);

  Object.defineProperty(window, 'crypto', descriptor);
});

test('falls back and reports errors when crypto access or event dispatch fails', () => {
  const descriptor = Object.getOwnPropertyDescriptor(window, 'crypto');
  const error = jest.spyOn(console, 'error').mockImplementation(() => {});
  Object.defineProperty(window, 'crypto', {
    configurable: true,
    value: {
      get randomUUID() {
        throw new Error('blocked');
      },
    },
  });

  expect(ensureDragWindowId()).toBeTruthy();
  expect(error).toHaveBeenCalledWith(
    'Failed to access crypto API for drag window id generation',
    expect.any(Error)
  );

  jest.spyOn(window, 'dispatchEvent').mockImplementation(() => {
    throw new Error('blocked');
  });
  expect(dispatchDropCompletion({ creativeId: '7' })).toBe(false);
  expect(error).toHaveBeenCalledWith(
    'Failed to dispatch creative drop completion event',
    expect.any(Error)
  );

  Object.defineProperty(window, 'crypto', descriptor);
  error.mockRestore();
});
