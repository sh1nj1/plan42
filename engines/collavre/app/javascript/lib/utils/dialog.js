/**
 * dialog — Promise-based, in-app replacements for the native browser dialogs
 * window.alert(), window.confirm() and window.prompt().
 *
 * Why: the packaged desktop app runs inside a Tauri (WKWebView) webview, which
 * does not reliably present native dialogs — alert() shows nothing, confirm()
 * returns false with no UI, and prompt() returns null. Every action gated on
 * `if (confirm(...))` then silently no-ops, and every `alert(error)` swallows
 * the message, so a failure looks like data loss. Rendering our own DOM modal
 * behaves identically in a browser and in the webview, removing the native
 * dialog dependency entirely.
 *
 * Public API (all return Promises so callers `await` them):
 *   await alertDialog(message)                  → undefined  (single OK button)
 *   await confirmDialog(message, { danger })    → boolean    (OK / Cancel)
 *   await promptDialog(message, { defaultValue })→ string|null (input + OK / Cancel)
 *
 * Reuses the shared .modal-dialog styles (modal_dialog.css) so any host app or
 * engine that bundles the collavre stylesheet renders these consistently.
 */

// Localized default button labels. Dialog *messages* are localized by the
// caller (server-side strings / data attributes); only the generic OK/Cancel
// buttons need a locale here. Locale comes from <html lang>, falling back to
// the webview/browser language.
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

/**
 * Internal modal builder shared by alert/confirm/prompt.
 *
 * @param {object} config
 * @param {string} config.message      Body text (rendered as text, never HTML).
 * @param {string|null} config.title   Optional header title.
 * @param {boolean} config.danger      Style the confirm button as destructive.
 * @param {boolean} config.showCancel  Render a Cancel button (confirm/prompt).
 * @param {string} config.confirmText  Confirm button label.
 * @param {string} config.cancelText   Cancel button label.
 * @param {object|null} config.input   When set, render a text input:
 *        { defaultValue?: string, placeholder?: string }
 * @returns {Promise<{ confirmed: boolean, value: string|null }>}
 *        confirmed=true on OK/Enter; false on Cancel/Escape/overlay dismiss.
 *        value=current input text (always '' when no input is rendered).
 */
function runDialog(config) {
  const labels = localeLabels()
  const {
    message,
    title = null,
    danger = false,
    showCancel = false,
    confirmText = labels.ok,
    cancelText = labels.cancel,
    input = null,
  } = config

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

    // Message text. textContent (not innerHTML): the message may contain
    // untrusted content, and native dialogs never rendered HTML either.
    // white-space: pre-wrap (CSS) preserves the \n line breaks they honored.
    if (message != null && String(message) !== '') {
      const text = document.createElement('div')
      text.className = 'confirm-dialog-message'
      text.textContent = String(message)
      body.appendChild(text)
    }

    // Optional input field (promptDialog).
    let inputEl = null
    if (input) {
      inputEl = document.createElement('input')
      inputEl.type = 'text'
      inputEl.className = 'modal-dialog-input'
      if (input.placeholder) inputEl.placeholder = input.placeholder
      inputEl.value = input.defaultValue != null ? String(input.defaultValue) : ''
      // Spacing when a message precedes the input.
      if (body.childNodes.length > 0) inputEl.style.marginTop = 'var(--space-3)'
      body.appendChild(inputEl)
    }

    dialog.appendChild(body)

    const footer = document.createElement('div')
    footer.className = 'modal-dialog-footer'

    let cancelBtn = null
    if (showCancel) {
      cancelBtn = document.createElement('button')
      cancelBtn.type = 'button'
      cancelBtn.className = 'modal-dialog-btn modal-dialog-btn-secondary'
      cancelBtn.textContent = cancelText
      footer.appendChild(cancelBtn)
    }

    const confirmBtn = document.createElement('button')
    confirmBtn.type = 'button'
    confirmBtn.className =
      'modal-dialog-btn ' +
      (danger ? 'modal-dialog-btn-danger' : 'modal-dialog-btn-primary')
    confirmBtn.textContent = confirmText
    footer.appendChild(confirmBtn)

    dialog.appendChild(footer)

    const entry = { dialog }
    let settled = false

    function close(confirmed) {
      if (settled) return
      settled = true
      const value = inputEl ? inputEl.value : ''
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
      resolve({ confirmed, value })
    }

    function onKeydown(e) {
      // Only the topmost dialog reacts to keys.
      if (stack[stack.length - 1] !== entry) return
      if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        close(false)
      } else if (e.key === 'Enter') {
        // In a text input, Enter submits (parity with native prompt).
        e.preventDefault()
        e.stopPropagation()
        close(true)
      }
    }

    if (cancelBtn) cancelBtn.addEventListener('click', () => close(false))
    confirmBtn.addEventListener('click', () => close(true))
    overlay.addEventListener('click', () => close(false))
    document.addEventListener('keydown', onKeydown, true)

    document.body.appendChild(overlay)
    document.body.appendChild(dialog)
    stack.push(entry)

    // Focus the input (prompt) or the confirm button (alert/confirm) so Enter
    // accepts, matching native dialog behavior.
    if (inputEl) {
      inputEl.focus()
      inputEl.select()
    } else {
      confirmBtn.focus()
    }
  })
}

/**
 * alertDialog — in-app replacement for window.alert().
 * Resolves (undefined) when dismissed. Usually fire-and-forget at call sites,
 * but returns a Promise so callers may `await` it when ordering matters.
 *
 *   alertDialog('Failed to save')
 *   await alertDialog('Done', { title: 'Export' })
 */
export function alertDialog(message, options = {}) {
  const { title = null, confirmText, danger = false } = options
  return runDialog({
    message,
    title,
    danger,
    showCancel: false,
    confirmText,
  }).then(() => undefined)
}

/**
 * confirmDialog — in-app replacement for window.confirm().
 * Resolves true when confirmed, false when cancelled/dismissed.
 *
 *   if (await confirmDialog(message, { danger: true })) doDestructiveThing()
 */
export function confirmDialog(message, options = {}) {
  const { confirmText, cancelText, danger = false, title = null } = options
  return runDialog({
    message,
    title,
    danger,
    showCancel: true,
    confirmText,
    cancelText,
  }).then((r) => r.confirmed)
}

/**
 * promptDialog — in-app replacement for window.prompt().
 * Resolves the entered string when confirmed, or null when cancelled/dismissed
 * (parity with native prompt, which returns null on cancel).
 *
 *   const name = await promptDialog('New name?', { defaultValue: current })
 *   if (name !== null) rename(name)
 */
export function promptDialog(message, options = {}) {
  const {
    defaultValue = '',
    placeholder = '',
    confirmText,
    cancelText,
    title = null,
  } = options
  return runDialog({
    message,
    title,
    showCancel: true,
    confirmText,
    cancelText,
    input: { defaultValue, placeholder },
  }).then((r) => (r.confirmed ? r.value : null))
}

export default confirmDialog
