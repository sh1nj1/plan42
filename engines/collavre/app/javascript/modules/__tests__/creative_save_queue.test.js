/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals';
import { CreativeSaveQueue } from '../creative_save_queue';

// A controllable timer harness so debounce behavior is deterministic without
// wall-clock waits. Mirrors setTimeout/clearTimeout semantics closely enough
// for the queue: fire() runs the most recently scheduled, uncleared callback.
function fakeTimers() {
  const scheduled = new Map();
  let nextId = 1;
  return {
    setTimer: (fn, ms) => {
      const id = nextId++;
      scheduled.set(id, { fn, ms });
      return id;
    },
    clearTimer: (id) => {
      scheduled.delete(id);
    },
    fire: (id) => {
      const entry = scheduled.get(id);
      if (!entry) throw new Error(`timer ${id} not scheduled (cleared or never set)`);
      scheduled.delete(id);
      entry.fn();
    },
    pending: () => scheduled.size,
    lastMs: () => [...scheduled.values()].map((e) => e.ms).pop(),
  };
}

// A save request whose settlement we control from the test.
function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe('CreativeSaveQueue', () => {
  describe('debounce (schedule / cancelTimer)', () => {
    test('schedule arms a timer with the configured debounce', () => {
      const timers = fakeTimers();
      const q = new CreativeSaveQueue({ debounceMs: 5000, setTimer: timers.setTimer, clearTimer: timers.clearTimer });
      const flush = jest.fn();

      q.schedule(flush);

      expect(timers.pending()).toBe(1);
      expect(timers.lastMs()).toBe(5000);
      expect(flush).not.toHaveBeenCalled();
    });

    test('flush runs when the timer fires', () => {
      const timers = fakeTimers();
      const q = new CreativeSaveQueue({ setTimer: timers.setTimer, clearTimer: timers.clearTimer });
      const flush = jest.fn();

      q.schedule(flush);
      timers.fire(1);

      expect(flush).toHaveBeenCalledTimes(1);
      expect(timers.pending()).toBe(0);
    });

    test('re-scheduling cancels the previous timer so only the latest fires', () => {
      const timers = fakeTimers();
      const q = new CreativeSaveQueue({ setTimer: timers.setTimer, clearTimer: timers.clearTimer });
      const first = jest.fn();
      const second = jest.fn();

      q.schedule(first);
      q.schedule(second);

      // Only one timer is live; the first was cleared.
      expect(timers.pending()).toBe(1);
      expect(() => timers.fire(1)).toThrow(); // first timer id was cleared
      timers.fire(2);
      expect(first).not.toHaveBeenCalled();
      expect(second).toHaveBeenCalledTimes(1);
    });

    test('default timers (no injection) schedule against the real timer API without illegal-invocation', () => {
      jest.useFakeTimers();
      try {
        // No setTimer/clearTimer injected — exercises the window-bound wrappers.
        // A regression that called setTimeout as a method of the queue threw
        // "Illegal invocation" in browsers; this guards the default path.
        const q = new CreativeSaveQueue({ debounceMs: 5000 });
        const flush = jest.fn();

        expect(() => q.schedule(flush)).not.toThrow();
        expect(flush).not.toHaveBeenCalled();
        jest.advanceTimersByTime(5000);
        expect(flush).toHaveBeenCalledTimes(1);

        // cancelTimer against the real timer API must also not throw.
        q.schedule(flush);
        expect(() => q.cancelTimer()).not.toThrow();
        jest.advanceTimersByTime(5000);
        expect(flush).toHaveBeenCalledTimes(1); // canceled — no second flush
      } finally {
        jest.useRealTimers();
      }
    });

    test('cancelTimer prevents a scheduled flush and is idempotent', () => {
      const timers = fakeTimers();
      const q = new CreativeSaveQueue({ setTimer: timers.setTimer, clearTimer: timers.clearTimer });
      const flush = jest.fn();

      q.schedule(flush);
      q.cancelTimer();
      q.cancelTimer(); // no throw on second call

      expect(timers.pending()).toBe(0);
    });
  });

  describe('single-flight (runExclusive)', () => {
    test('runs execute and tracks saving state across the request lifecycle', async () => {
      const q = new CreativeSaveQueue();
      const d = deferred();
      const execute = jest.fn(() => d.promise);

      expect(q.saving).toBe(false);
      const p = q.runExclusive(execute);

      expect(execute).toHaveBeenCalledTimes(1);
      expect(q.saving).toBe(true);
      expect(q.promise).toBe(p);

      d.resolve('ok');
      await p;
      expect(q.saving).toBe(false);
    });

    test('coalesces: a second call while saving returns the in-flight promise without re-running execute', async () => {
      const q = new CreativeSaveQueue();
      const d = deferred();
      const execute = jest.fn(() => d.promise);
      const second = jest.fn(() => deferred().promise);

      const p1 = q.runExclusive(execute);
      const p2 = q.runExclusive(second);

      expect(p2).toBe(p1); // same in-flight promise
      expect(second).not.toHaveBeenCalled(); // no double save
      expect(execute).toHaveBeenCalledTimes(1);

      d.resolve();
      await p1;
    });

    test('a fresh save runs after the previous one settles', async () => {
      const q = new CreativeSaveQueue();
      const d1 = deferred();
      const execute1 = jest.fn(() => d1.promise);
      const d2 = deferred();
      const execute2 = jest.fn(() => d2.promise);

      const p1 = q.runExclusive(execute1);
      d1.resolve();
      await p1;
      expect(q.saving).toBe(false);

      q.runExclusive(execute2);
      expect(execute2).toHaveBeenCalledTimes(1);
      expect(q.saving).toBe(true);
      d2.resolve();
    });

    test('execute returning null (nothing to persist) does not enter the saving state', async () => {
      const q = new CreativeSaveQueue();
      const execute = jest.fn(() => null);

      const p = q.runExclusive(execute);

      expect(execute).toHaveBeenCalledTimes(1);
      expect(q.saving).toBe(false);
      await expect(p).resolves.toBeUndefined();
    });

    test('runExclusive cancels a pending debounce timer before saving', () => {
      const timers = fakeTimers();
      const q = new CreativeSaveQueue({ setTimer: timers.setTimer, clearTimer: timers.clearTimer });
      const flush = jest.fn();

      q.schedule(flush);
      expect(timers.pending()).toBe(1);

      q.runExclusive(() => deferred().promise);

      expect(timers.pending()).toBe(0); // debounce canceled — no redundant trailing save
      expect(flush).not.toHaveBeenCalled();
    });

    test('clears saving even when the request rejects', async () => {
      const q = new CreativeSaveQueue();
      const d = deferred();
      const execute = jest.fn(() => d.promise);

      const p = q.runExclusive(execute);
      expect(q.saving).toBe(true);

      d.reject(new Error('boom'));
      await expect(p).rejects.toThrow('boom');
      expect(q.saving).toBe(false);
    });

    test('after a rejection a subsequent save can run', async () => {
      const q = new CreativeSaveQueue();
      const d1 = deferred();
      const p1 = q.runExclusive(() => d1.promise);
      d1.reject(new Error('fail'));
      await expect(p1).rejects.toThrow();

      const execute2 = jest.fn(() => deferred().promise);
      q.runExclusive(execute2);
      expect(execute2).toHaveBeenCalledTimes(1);
      expect(q.saving).toBe(true);
    });
  });
});
