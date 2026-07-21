// Reopen-after-connect intent for the Linear integration modal.
//
// When the OAuth popup finishes it posts `linearConnected` and the opener does a
// full `window.location.reload()` so the server re-renders the modal in its
// project-linking state (the account now exists). But the modal defaults to
// `display:none` and nothing re-opens it after the reload — so the connect→link
// step is invisible and the user has to click "Linear 연결" again to reach it.
//
// This module persists a one-shot "reopen the modal" flag across that reload.
// Factored out of the side-effectful collavre_linear.js opener so the behavior
// is unit-testable (that file is imported only for its window/turbo listeners).

export const LINEAR_REOPEN_KEY = 'linearReopenModal';

// Record that the modal should reopen after the next full-page reload. Tolerates
// a missing or throwing storage (private-mode Safari, packaged WKWebView) — the
// reopen is a convenience and must never throw inside the postMessage handler.
export function markReopenAfterConnect(storage) {
  try {
    if (storage) storage.setItem(LINEAR_REOPEN_KEY, '1');
  } catch (e) {
    /* storage unavailable — skip the reopen nicety */
  }
}

// Consume the reopen intent: returns true at most once, then clears the flag so
// a later unrelated reload (e.g. after linking succeeds) does not reopen it.
export function consumeReopenAfterConnect(storage) {
  try {
    if (storage && storage.getItem(LINEAR_REOPEN_KEY)) {
      storage.removeItem(LINEAR_REOPEN_KEY);
      return true;
    }
  } catch (e) {
    /* storage unavailable — treat as no pending reopen */
  }
  return false;
}
