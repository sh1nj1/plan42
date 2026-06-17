// Read the typo-correction profile the server exposes on #comments-popup's
// dataset. Shared by the chat composer (Phase 1) and the Lexical editor
// (Phase 2) so both read the same source of truth.

export function readTypoSettings(root) {
  if (!root) return null
  const d = root.dataset
  if (d.typoEnabled == null) return null
  return {
    enabled: d.typoEnabled === 'true',
    threshold: parseInt(d.typoThreshold, 10) || 80,
    onVoice: d.typoOnVoice === 'true',
    onSoftKeyboard: d.typoOnSoftKeyboard === 'true',
    onPhysicalKeyboard: d.typoOnPhysicalKeyboard === 'true',
    inChat: d.typoInChat === 'true',
    inEditor: d.typoInEditor === 'true',
  }
}

export function readTypoLabels(root) {
  const d = root?.dataset || {}
  return {
    keep: d.typoKeepLabel,
    custom: d.typoCustomLabel,
    inputLabel: d.typoInputLabel,
  }
}

// The engine can be mounted at a subpath (e.g. /collavre), so a root-relative
// default would 404 — prefer the engine-rendered endpoint when present.
export function readTypoEndpoint(root) {
  return root?.dataset?.typoEndpoint || '/typo_corrections'
}
