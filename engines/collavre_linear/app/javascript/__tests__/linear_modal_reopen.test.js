import {
  LINEAR_REOPEN_KEY,
  markReopenAfterConnect,
  consumeReopenAfterConnect,
  safeSessionStorage,
} from '../linear_modal_reopen.js';

// Minimal in-memory Storage stand-in (jsdom's is fine too, but this keeps the
// unit test free of environment setup and lets us model a throwing storage).
function fakeStorage() {
  const map = new Map();
  return {
    setItem: (k, v) => map.set(k, String(v)),
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    removeItem: (k) => map.delete(k),
    _size: () => map.size,
  };
}

describe('safeSessionStorage', () => {
  test('returns the storage object when Web Storage is available', () => {
    // jsdom provides a working window.sessionStorage.
    expect(safeSessionStorage()).toBe(window.sessionStorage);
  });

  test('returns null when the window.sessionStorage getter itself throws', () => {
    // Web Storage disabled by policy (packaged WKWebView, storage-blocked
    // browser) throws on the property *access*, before any value is passed to
    // mark/consume. safeSessionStorage must absorb it so callers never throw.
    const original = Object.getOwnPropertyDescriptor(window, 'sessionStorage');
    Object.defineProperty(window, 'sessionStorage', {
      configurable: true,
      get() { throw new Error('SecurityError: storage disabled'); },
    });
    try {
      expect(() => safeSessionStorage()).not.toThrow();
      expect(safeSessionStorage()).toBeNull();
    } finally {
      if (original) Object.defineProperty(window, 'sessionStorage', original);
    }
  });
});

describe('markReopenAfterConnect', () => {
  test('persists the unscoped sentinel when no creative id is given', () => {
    const storage = fakeStorage();
    markReopenAfterConnect(storage);
    expect(storage.getItem(LINEAR_REOPEN_KEY)).toBe('1');
  });

  test('persists the creative id when given (scoped reopen)', () => {
    const storage = fakeStorage();
    markReopenAfterConnect(storage, 42);
    expect(storage.getItem(LINEAR_REOPEN_KEY)).toBe('42');
  });

  test('falls back to the unscoped sentinel for an empty creative id', () => {
    const storage = fakeStorage();
    markReopenAfterConnect(storage, '');
    expect(storage.getItem(LINEAR_REOPEN_KEY)).toBe('1');
  });

  test('tolerates a null storage without throwing', () => {
    expect(() => markReopenAfterConnect(null)).not.toThrow();
  });

  test('swallows storage errors (private mode / WKWebView)', () => {
    const throwing = { setItem: () => { throw new Error('QuotaExceeded'); } };
    expect(() => markReopenAfterConnect(throwing)).not.toThrow();
  });
});

describe('consumeReopenAfterConnect', () => {
  test('returns true exactly once, then clears the flag (regression)', () => {
    // Without the one-shot clear, every subsequent reload — including the one
    // after a successful link — would reopen the modal. It must fire once.
    const storage = fakeStorage();
    markReopenAfterConnect(storage);

    expect(consumeReopenAfterConnect(storage)).toBe(true);
    expect(consumeReopenAfterConnect(storage)).toBe(false);
    expect(storage.getItem(LINEAR_REOPEN_KEY)).toBeNull();
  });

  test('reopens only when the current creative matches the stored one', () => {
    const storage = fakeStorage();
    markReopenAfterConnect(storage, 42); // popup connected creative 42
    // Opener is on the same creative → reopen.
    expect(consumeReopenAfterConnect(storage, 42)).toBe(true);
  });

  test('does NOT reopen when the opener navigated to a different creative', () => {
    // Codex P2: mid-flow navigation must not surface the wrong creative's modal.
    const storage = fakeStorage();
    markReopenAfterConnect(storage, 42); // popup connected creative 42
    // Opener moved to creative 99 before the reload → no reopen, flag cleared.
    expect(consumeReopenAfterConnect(storage, 99)).toBe(false);
    expect(storage.getItem(LINEAR_REOPEN_KEY)).toBeNull();
  });

  test('clears a mismatched intent so it never fires on a later matching visit', () => {
    const storage = fakeStorage();
    markReopenAfterConnect(storage, 42);
    consumeReopenAfterConnect(storage, 99); // mismatch on the reload
    // Later navigation back to creative 42 must NOT auto-open — intent was spent.
    expect(consumeReopenAfterConnect(storage, 42)).toBe(false);
  });

  test('matches across id string/number coercion', () => {
    const storage = fakeStorage();
    markReopenAfterConnect(storage, 42);        // stored as '42'
    expect(consumeReopenAfterConnect(storage, '42')).toBe(true); // dataset is a string
  });

  test('unscoped sentinel reopens regardless of current creative (legacy)', () => {
    const storage = fakeStorage();
    markReopenAfterConnect(storage);            // no id → '1'
    expect(consumeReopenAfterConnect(storage, 7)).toBe(true);
  });

  test('returns false when no reopen was pending', () => {
    expect(consumeReopenAfterConnect(fakeStorage())).toBe(false);
  });

  test('tolerates a null storage', () => {
    expect(consumeReopenAfterConnect(null)).toBe(false);
  });

  test('swallows storage errors and reports no pending reopen', () => {
    const throwing = { getItem: () => { throw new Error('SecurityError'); } };
    expect(consumeReopenAfterConnect(throwing)).toBe(false);
  });

  test('end-to-end via safeSessionStorage: mark on connect, consume once', () => {
    // The call sites pass safeSessionStorage() rather than window.sessionStorage
    // directly, so the whole flow must survive a storage-backed session.
    const s = safeSessionStorage();
    if (!s) return; // jsdom always provides it; guard just in case
    s.removeItem(LINEAR_REOPEN_KEY);
    markReopenAfterConnect(s);
    expect(consumeReopenAfterConnect(s)).toBe(true);
    expect(consumeReopenAfterConnect(s)).toBe(false);
  });

  test('end-to-end: mark on connect, consume on the next load', () => {
    // Mirrors the real flow: the postMessage handler marks, the reload happens,
    // then turbo:load consumes the flag and opens the modal exactly once.
    const storage = fakeStorage();
    markReopenAfterConnect(storage);          // linearConnected received
    const reopenedFirstLoad = consumeReopenAfterConnect(storage);   // turbo:load
    const reopenedSecondLoad = consumeReopenAfterConnect(storage);  // later nav
    expect(reopenedFirstLoad).toBe(true);
    expect(reopenedSecondLoad).toBe(false);
  });
});
