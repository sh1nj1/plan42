// Inbox button click → dispatch creative-comments-click event.
// The popup_controller handles opening/closing the chat popup.

document.addEventListener('click', function (e) {
  const btn = e.target.closest('.inbox-menu-btn')
  if (!btn) return

  e.preventDefault()
  e.stopPropagation()

  const creativeId = btn.dataset.creativeId
  if (!creativeId) return

  document.dispatchEvent(
    new CustomEvent('creative-comments-click', {
      bubbles: true,
      detail: { button: btn, creativeId }
    })
  )
})
