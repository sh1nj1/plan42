// Pure logic for client-side typo correction (Phase 1: chat input).
//
// This module holds the framework-free core so it can be unit-tested without a
// DOM: device classification, the 2D gating decision (mirrors the server's
// `Collavre::User#typo_correction_active_for?`), candidate-list construction for
// the selection popup, and edit anchoring/application with re-anchoring of the
// remaining edits after one is applied.
//
// The overlay highlight is a *volatile* presentation layer — the textarea value
// is the only canonical text. Nothing here ever serializes a highlight.

export const DEVICE_VOICE = 'voice'
export const DEVICE_SOFT_KEYBOARD = 'soft_keyboard'
export const DEVICE_PHYSICAL_KEYBOARD = 'physical_keyboard'

// Classify the active typing device from the signals we can observe.
//
// - Voice dictation is explicit (the composer exposes its recognition state).
// - A physical keyboard fires a `keydown` for a printable key immediately
//   before the resulting `input` event. Soft keyboards and IME composition
//   insert text without that printable keydown (key is 'Unidentified'/'Process'
//   or no keydown at all), which is the standard heuristic we rely on.
export function detectDevice({ voiceActive = false, lastPrintableKeydownAt = null, inputAt = null } = {}) {
  if (voiceActive) return DEVICE_VOICE
  if (lastPrintableKeydownAt == null || inputAt == null) return DEVICE_SOFT_KEYBOARD
  // A printable keydown that landed within the same input tick means a physical
  // key produced this character.
  const delta = inputAt - lastPrintableKeydownAt
  if (delta >= 0 && delta <= 50) return DEVICE_PHYSICAL_KEYBOARD
  return DEVICE_SOFT_KEYBOARD
}

// Mirror of the server-side 2D gate so the client avoids a pointless round-trip
// when the feature is off for this device/location. The server re-checks; this
// is an optimization, not the source of truth.
export function shouldRun(settings, { device, location }) {
  if (!settings || settings.enabled !== true) return false

  const deviceOn =
    device === DEVICE_VOICE ? settings.onVoice
      : device === DEVICE_SOFT_KEYBOARD ? settings.onSoftKeyboard
        : device === DEVICE_PHYSICAL_KEYBOARD ? settings.onPhysicalKeyboard
          : false
  if (deviceOn !== true) return false

  const locationOn =
    location === 'chat' ? settings.inChat
      : location === 'editor' ? settings.inEditor
        : false
  return locationOn === true
}

// Build the popup's option list for one edit: the word currently sitting in the
// document first (so Enter = keep), then the suggestions in confidence order,
// de-duplicated. `currentValue` is whatever text is actually in the textarea at
// the edit's span right now (original word, or the corrected word if it was
// auto-applied). `originalWord` is the pre-correction text, surfaced as the undo
// option when the current value is already the suggestion.
export function buildCandidateList({ currentValue, originalWord, suggestions = [] }) {
  const seen = new Set()
  const list = []
  const push = (value, role) => {
    if (value == null || value === '') return
    if (seen.has(value)) return
    seen.add(value)
    list.push({ value, label: value, isCurrent: value === currentValue, role })
  }

  // Current document value is always the pre-selected, pre-filled option.
  push(currentValue, currentValue === originalWord ? 'original' : 'applied')
  // If we're showing a corrected word, the original is the undo option.
  push(originalWord, 'original')
  // Suggestions, highest confidence first (assumed already sorted; sort defensively).
  ;[...suggestions]
    .sort((a, b) => (b.confidence ?? 0) - (a.confidence ?? 0))
    .forEach((s) => push(s.suggestion, 'suggestion'))

  return list
}

// Attach character offsets to each edit. Prefer the server-supplied `offset`
// (the first occurrence the server verified is *outside* a protected span) so a
// duplicate word sitting inside code/URL/markup is never anchored — anchoring by
// our own search would bind the first textual occurrence, which can be the
// protected one the server already excluded. We only trust `offset` if the
// substring still matches there (text is identical to what the server saw).
// Without an offset we fall back to a left-to-right search, advancing the cursor
// so repeated words bind to distinct occurrences. Edits whose original can no
// longer be found are dropped — the caller re-runs the detector.
export function anchorEdits(text, edits = []) {
  const anchored = []
  let cursor = 0
  for (const edit of edits) {
    if (!edit || !edit.original) continue
    let idx
    if (
      Number.isInteger(edit.offset)
      && text.slice(edit.offset, edit.offset + edit.original.length) === edit.original
    ) {
      idx = edit.offset
    } else {
      idx = text.indexOf(edit.original, cursor)
    }
    if (idx === -1) continue
    anchored.push({ ...edit, start: idx, end: idx + edit.original.length })
    cursor = Math.max(cursor, idx + edit.original.length)
  }
  return anchored
}

// Replace the span [start, end) of `text` with `replacement` and return the new
// text plus the delta, so remaining edits can be shifted. We re-anchor by delta
// rather than re-searching to avoid mis-binding when the same word repeats.
export function applyEditAt(text, { start, end, replacement }) {
  const before = text.slice(0, start)
  const after = text.slice(end)
  const newText = before + replacement + after
  const delta = replacement.length - (end - start)
  return { text: newText, delta }
}

// Shift every edit positioned at/after `fromOffset` by `delta`. Edits before the
// applied span are untouched; the applied edit itself should be removed by the
// caller before calling this.
export function shiftEditsAfter(edits, fromOffset, delta) {
  return edits.map((edit) => {
    if (edit.start >= fromOffset) {
      return { ...edit, start: edit.start + delta, end: edit.end + delta }
    }
    return edit
  })
}

// Partition edits the server returned into auto-applied (confidence at/above the
// user's threshold) and candidates (below it). Threshold is 0–100 to match the
// profile setting; confidence is 0–1 from the model.
export function partitionByThreshold(edits = [], threshold = 80) {
  const cut = threshold / 100
  const autoApplied = []
  const candidates = []
  for (const edit of edits) {
    if ((edit.confidence ?? 0) >= cut) autoApplied.push(edit)
    else candidates.push(edit)
  }
  return { autoApplied, candidates }
}
