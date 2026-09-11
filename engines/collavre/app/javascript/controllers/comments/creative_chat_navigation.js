// Keep workspace synchronization separate from explicit chat-open intent.
export function handleCreativeChatClick(popup, detail) {
  const { button, creativeId, highlightId, workspaceSync } = detail
  if (!button) return
  const openRequested = detail.openRequested === true
  const targetId = creativeId || button.dataset.creativeId
  if (workspaceSync && !popup.isDocked() && !openRequested) {
    closePreviousFloatingChat(popup, targetId)
    return
  }
  if (!creativeId && button.dataset.workspaceNavigationState === 'true' && popup.isDocked()) {
    popup.resetDockedToEmpty()
    return
  }
  const shouldExpand = !workspaceSync || openRequested
  if (popup.element.style.display === 'flex' && popup.element.dataset.creativeId === targetId) {
    updateCurrentChat(popup, { button, creativeId, targetId, highlightId, shouldExpand, openRequested })
    return
  }
  if (shouldExpand) popup.expandDocked()
  openCreativeChat(popup, button, { creativeId, highlightId })
}

function closePreviousFloatingChat(popup, targetId) {
  if (popup.element.style.display === 'flex' && popup.element.dataset.creativeId !== String(targetId || '')) {
    popup.close()
  }
}

function updateCurrentChat(popup, { button, creativeId, targetId, highlightId, shouldExpand, openRequested }) {
  if (popup.isDocked()) {
    if (shouldExpand) popup.expandDocked()
    if (highlightId) popup.reloadDockedHighlight(targetId, highlightId)
    return
  }
  if (openRequested) {
    if (highlightId) popup.open(button, { creativeId, highlightId })
    return
  }
  popup.close()
}

function openCreativeChat(popup, button, { creativeId, highlightId }) {
  const options = { creativeId }
  if (highlightId) options.highlightId = highlightId
  popup.open(button, options)
}
