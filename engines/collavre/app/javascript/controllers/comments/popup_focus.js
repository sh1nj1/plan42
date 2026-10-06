// Only the focused opener may yield to initial chat autofocus after loading.
export function openingFocusOptions(button) {
  return button && document.activeElement === button ? { openingControl: button } : {}
}
