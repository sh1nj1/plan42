/**
 * confirmDialog — Promise-based, in-app replacement for window.confirm().
 *
 * Why: the packaged desktop app runs inside a Tauri (WKWebView) webview, which
 * does not reliably present native window.confirm()/alert()/prompt() dialogs —
 * the call returns false with no UI, so every destructive action gated on
 * `if (confirm(...))` silently no-ops (e.g. a creative could not be deleted in
 * the desktop build). Rendering our own DOM modal behaves identically in a
 * browser and in the webview, removing the native-dialog dependency entirely.
 *
 * Reuses the shared .modal-dialog styles (modal_dialog.css) and focus trap
 * (modules/modal_dialog.js applies to any .modal-dialog).
 *
 * Returns Promise<boolean>: true = confirmed, false = cancelled/dismissed.
 *
 *   if (await confirmDialog(message, { danger: true })) doDestructiveThing()
 */

// Localized default button labels. The confirm *message* is already localized
// server-side; only the buttons need a locale here. Locale comes from the
// <html lang> the layout sets, falling back to the webview/browser language.
const LABELS = {
  ko: { ok: '확인', cancel: '취소' },
  en: { ok: 'OK', cancel: 'Cancel' },
}

function localeLabels() {
  const lang = (
    document.documentElement.lang ||
    navigator.language ||
    'en'
  ).toLowerCase()
  const key = Object.keys(LABELS).find((l) => lang.startsWith(l))
  return LABELS[key] || LABELS.en
}

// Stack of open dialogs so keyboard handling only targets the topmost one.
const stack = []

export function confirmDialog(message, options = {}) {
  const labels = localeLabels()
  const {
    confirmText = labels.ok,
    cancelText = labels.cancel,
    danger = false,
    title = null,
  } = options

  return new Promise((resolve) => {
    const previousFocus = document.activeElement

    const overlay = document.createElement('div')
    overlay.className = 'modal-dialog-overlay open'

    const dialog = document.createElement('div')
    dialog.className = 'modal-dialog modal-dialog-compact open'
    dialog.setAttribute('role', 'alertdialog')
    dialog.setAttribute('aria-modal', 'true')

    if (title) {
      const header = document.createElement('div')
      header.className = 'modal-dialog-header'
      const titleEl = document.createElement('div')
      titleEl.className = 'modal-dialog-title'
      titleEl.textContent = title
      header.appendChild(titleEl)
      dialog.appendChild(header)
    }

    const body = document.createElement('div')
    body.className = 'modal-dialog-body'
    const text = document.createElement('div')
    text.className = 'confirm-dialog-message'
    // textContent (not innerHTML): the message may contain untrusted content,
    // and native confirm() never rendered HTML either. white-space: pre-wrap
    // (CSS) preserves the \n line breaks native confirm honored.
    text.textContent = message == null ? '' : String(message)
    body.appendChild(text)
    dialog.appendChild(body)

    const footer = document.createElement('div')
    footer.className = 'modal-dialog-footer'

    const cancelBtn = document.createElement('button')
    cancelBtn.type = 'button'
    cancelBtn.className = 'modal-dialog-btn modal-dialog-btn-secondary'
    cancelBtn.textContent = cancelText

    const confirmBtn = document.createElement('button')
    confirmBtn.type = 'button'
    confirmBtn.className =
      'modal-dialog-btn ' +
      (danger ? 'modal-dialog-btn-danger' : 'modal-dialog-btn-primary')
    confirmBtn.textContent = confirmText

    footer.appendChild(cancelBtn)
    footer.appendChild(confirmBtn)
    dialog.appendChild(footer)

    const entry = { dialog }
    let settled = false

    function close(result) {
      if (settled) return
      settled = true
      const i = stack.indexOf(entry)
      if (i !== -1) stack.splice(i, 1)
      document.removeEventListener('keydown', onKeydown, true)
      overlay.remove()
      dialog.remove()
      // Restore focus to whatever triggered the dialog.
      try {
        if (previousFocus && typeof previousFocus.focus === 'function') {
          previousFocus.focus()
        }
      } catch (_) {
        /* element gone — ignore */
      }
      resolve(result)
    }

    function onKeydown(e) {
      // Only the topmost dialog reacts to keys.
      if (stack[stack.length - 1] !== entry) return
      if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        close(false)
      } else if (e.key === 'Enter') {
        e.preventDefault()
        e.stopPropagation()
        close(true)
      }
    }

    cancelBtn.addEventListener('click', () => close(false))
    confirmBtn.addEventListener('click', () => close(true))
    overlay.addEventListener('click', () => close(false))
    document.addEventListener('keydown', onKeydown, true)

    document.body.appendChild(overlay)
    document.body.appendChild(dialog)
    stack.push(entry)

    // Focus the confirm button for parity with native confirm (Enter accepts).
    confirmBtn.focus()
  })
}

export default confirmDialog
