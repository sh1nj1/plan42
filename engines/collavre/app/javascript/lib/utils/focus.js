// Presence stays active until a close/save finishes, even while the form is hidden.
// Keep the node rather than a boolean so a workspace replacement releases it.
let editingCreative = null
document.addEventListener('creative-editing:start', () => {
  editingCreative = document.getElementById('inline-edit-form')
})
document.addEventListener('creative-editing:stop', () => { editingCreative = null })
document.addEventListener('turbo:before-cache', () => { editingCreative = null })

// Check at execution time: focus may change while a frame is queued.
export function focusWhenAvailable(target, { explicit = false, openingControl = null } = {}) {
  const focus = () => {
    if (!isVisible(target) || target.disabled) return
    if (!explicit && autoFocusBlocked(target, openingControl)) return
    target.focus()
  }
  // Keep direct actions synchronous (including mobile keyboard activation).
  if (explicit) focus()
  else requestAnimationFrame(focus)
}

function isVisible(element) {
  if (!element?.isConnected) return false
  for (let node = element; node; node = node.parentElement) {
    const style = window.getComputedStyle(node)
    if (node.hidden || node.inert || style.display === 'none' || style.visibility === 'hidden') return false
  }
  return true
}

function autoFocusBlocked(target, openingControl) {
  const active = document.activeElement
  if (active !== target && active !== openingControl && active?.closest('button, a[href], [tabindex], input, textarea, select, [contenteditable]:not([contenteditable="false"])')) return true
  // The shared editor stays open even when save controls temporarily blur it.
  return editingCreative?.isConnected || isVisible(document.getElementById('inline-edit-form'))
}
