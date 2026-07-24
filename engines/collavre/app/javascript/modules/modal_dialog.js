/**
 * Modal Dialog — shared behavior for .modal-dialog elements.
 *
 * Auto-applies focus trapping (Tab/Shift+Tab cycles within the dialog)
 * to any element with the .modal-dialog class via event delegation.
 *
 * Import this module once in the application entrypoint to activate.
 */

const FOCUSABLE_SELECTOR =
  'input:not([disabled]), select:not([disabled]), textarea:not([disabled]), button:not([disabled]), [tabindex]:not([tabindex="-1"])'

function getFocusableElements(dialog) {
  return Array.from(dialog.querySelectorAll(FOCUSABLE_SELECTOR)).filter(
    (el) => el.offsetParent !== null
  )
}

function handleKeydown(event) {
  if (event.key !== 'Tab') return

  const dialog = event.target.closest('.modal-dialog')
  if (!dialog) return

  const focusable = getFocusableElements(dialog)
  if (focusable.length === 0) return

  const first = focusable[0]
  const last = focusable[focusable.length - 1]

  if (event.shiftKey && document.activeElement === first) {
    event.preventDefault()
    last.focus()
  } else if (!event.shiftKey && document.activeElement === last) {
    event.preventDefault()
    first.focus()
  }
}

document.addEventListener('keydown', handleKeydown)
