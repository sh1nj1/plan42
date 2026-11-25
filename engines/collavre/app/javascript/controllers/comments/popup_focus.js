// A click may leave prior focus unchanged; only exempt that pre-loading control.
export function openingFocusOptions(button) {
  const active = document.activeElement
  return button && active?.matches('button, a[href]') ? { openingControl: active } : {}
}
