// The autosave request lifecycle extracted from creative_row_editor.js.
//
// The inline editor persists edits on a debounce and also saves directly on
// structural changes (reorder, indent, progress toggle). Two invariants kept
// getting re-broken across dozens of fix commits ("Prevent double saves...",
// "Skip in-flight request during queue deduplication"):
//
//   1. Debounce: rapid edits collapse into a single trailing save; re-arming
//      the timer must cancel the previous one.
//   2. Single-flight: at most one save request is in flight at a time. A save
//      requested while one is running must NOT start a second request — it
//      returns the in-flight promise. (Dirty-tracking in the editor re-arms and
//      a later schedule/flush persists the newer buffer.)
//
// This class owns exactly those two concerns — the debounce timer and the
// single-flight guard around the request promise. It deliberately does NOT own
// the editor's dirty flags (isDirty / pendingSave), which track *what* changed;
// this owns *when the request runs*. Behavior is identical to the original
// inline `saveTimer` / `saving` / `savePromise` logic; the timer functions are
// injectable so the state machine is testable without real timers.
export class CreativeSaveQueue {
  constructor({ debounceMs = 5000, setTimer, clearTimer } = {}) {
    this._debounceMs = debounceMs;
    // Wrap the timer functions so they are invoked as free functions. Passing
    // `setTimeout`/`clearTimeout` directly and calling them as `this._setTimer(...)`
    // would invoke them with `this === queue`, which throws "Illegal invocation"
    // in real browsers (jsdom does not, which is why unit tests can't catch it).
    // Tests inject their own timer fns; production uses these window-bound wrappers.
    this._setTimer = setTimer || ((fn, ms) => setTimeout(fn, ms));
    this._clearTimer = clearTimer || ((id) => clearTimeout(id));
    this._timer = null;
    this._saving = false;
    this._promise = Promise.resolve();
  }

  /** True while a save request is in flight. */
  get saving() {
    return this._saving;
  }

  /** The most recent (possibly in-flight) save promise. */
  get promise() {
    return this._promise;
  }

  /**
   * Arm the debounce timer to invoke `flush` after `debounceMs`. Re-arming
   * cancels any previously scheduled flush, so only the latest edit's timer
   * fires (trailing debounce).
   * @param {() => void} flush
   */
  schedule(flush) {
    this.cancelTimer();
    this._timer = this._setTimer(() => {
      this._timer = null;
      flush();
    }, this._debounceMs);
  }

  /** Cancel a pending debounce timer, if any. Idempotent. */
  cancelTimer() {
    if (this._timer !== null) {
      this._clearTimer(this._timer);
      this._timer = null;
    }
  }

  /**
   * Run `execute` under the single-flight guard.
   *
   * - If a save is already in flight, returns the in-flight promise WITHOUT
   *   invoking `execute` (the coalescing invariant).
   * - Otherwise cancels any pending debounce, then invokes `execute`. `execute`
   *   returns the save request promise, or a nullish value to signal "nothing
   *   to persist" (e.g. empty content) — in which case no in-flight state is
   *   entered and a resolved promise is returned. Invoking `execute` before
   *   committing `saving` preserves the original ordering, where an empty-save
   *   short-circuit never flips the in-flight flag.
   *
   * `saving` is cleared when the returned promise settles (success or failure).
   * @param {() => (Promise|null|undefined)} execute
   * @returns {Promise}
   */
  runExclusive(execute) {
    if (this._saving) return this._promise;
    this.cancelTimer();
    const request = execute();
    if (request == null) return Promise.resolve();
    this._saving = true;
    this._promise = Promise.resolve(request).finally(() => {
      this._saving = false;
    });
    return this._promise;
  }
}
