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

// Read window.sessionStorage defensively. When Web Storage is disabled by policy
// (packaged WKWebView, a browser blocking storage for the site) the property
// getter *itself* throws — before any value reaches mark/consume — so guarding
// only inside those functions is not enough; the access site must be guarded
// too. Returns null when unavailable so callers never take an uncaught throw.
export function safeSessionStorage() {
  try {
    return window.sessionStorage;
  } catch (e) {
    return null;
  }
}

// Unscoped sentinel. Stored when the OAuth creative id is unknown so the reopen
// still fires (matches any page) — the scoped path stores the id instead. Must
// be a value no serialized creative id can equal: ids are positive integers and
// serialize to digit strings, so a non-digit marker never collides. (A previous
// '1' sentinel collided with creative id 1 — that page's scoped reopen was
// misread as unscoped and skipped the mismatch guard.)
const UNSCOPED = '*';

// Record that the modal should reopen after the next full-page reload, scoped to
// the creative the OAuth popup was opened for. The popup posts its own
// creativeId; storing it lets consume verify the reloaded page still shows that
// same creative before reopening — otherwise, if the opener navigated to a
// different creative while the popup was open, the reload would auto-open the
// wrong creative's link modal and the user could link the project to it.
// Tolerates a missing or throwing storage (private-mode Safari, packaged
// WKWebView) — the reopen is a convenience and must never throw inside the
// postMessage handler.
export function markReopenAfterConnect(storage, creativeId) {
  const value =
    creativeId != null && String(creativeId) !== '' ? String(creativeId) : UNSCOPED;
  try {
    if (storage) storage.setItem(LINEAR_REOPEN_KEY, value);
  } catch (e) {
    /* storage unavailable — skip the reopen nicety */
  }
}

// Consume the reopen intent: returns true at most once, then clears the flag so
// a later unrelated reload (e.g. after linking succeeds) does not reopen it. The
// flag is cleared on the first consume regardless of match, so a stale intent
// (opener navigated elsewhere) never lingers to reopen the modal on some later
// visit. Returns true only when the stored creative id matches the current page
// (or when the legacy unscoped sentinel was stored).
export function consumeReopenAfterConnect(storage, currentCreativeId) {
  try {
    if (!storage) return false;
    const stored = storage.getItem(LINEAR_REOPEN_KEY);
    if (!stored) return false;
    storage.removeItem(LINEAR_REOPEN_KEY); // one-shot regardless of match
    if (stored === UNSCOPED) return true;
    return String(currentCreativeId == null ? '' : currentCreativeId) === stored;
  } catch (e) {
    /* storage unavailable — treat as no pending reopen */
  }
  return false;
}
