import '../../components/creative_header_progress'

export function clearChatActiveRow() {
  document.querySelectorAll('creative-tree-row.chat-active').forEach(row => {
    row.classList.remove('chat-active')
  })
}

export function markChatActiveRow(popup, creativeId) {
  clearChatActiveRow()
  if (!creativeId) return
  const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
  if (row) row.classList.add('chat-active')
  observeCreativeProgress(popup, row, creativeId)
  watchTreeUpdates(popup)
}

function watchTreeUpdates(popup) {
  if (!popup.hasProgressTarget || popup.handleProgressTreeUpdate) return

  popup.handleProgressTreeUpdate = () => {
    const creativeId = popup.progressCreativeId
    if (creativeId && popup.element.style.display === 'flex') markChatActiveRow(popup, creativeId)
  }
  document.addEventListener('creative-tree:updated', popup.handleProgressTreeUpdate)
}

export function disconnectCreativeProgress(popup) {
  popup.progressObserver?.disconnect()
  document.removeEventListener('creative-tree:updated', popup.handleProgressTreeUpdate)
  popup.handleProgressTreeUpdate = null
}

export function observeCreativeProgress(popup, row, creativeId) {
  if (!popup.hasProgressTarget) return
  popup.progressObserver?.disconnect()
  if (popup.progressCreativeId !== creativeId) popup.progressTarget.value = undefined
  popup.progressCreativeId = creativeId
  popup.progressTarget.removeAttribute('data-row-progress')
  if (!row) return

  const sync = () => {
    const value = row.dataset.progressValue
    const progress = value === undefined || value === '' ? undefined : Number(value)
    popup.progressTarget.value = progress
    popup.progressTarget.toggleAttribute('data-row-progress', Number.isFinite(progress))
  }
  sync()
  popup.progressObserver = new MutationObserver(sync)
  popup.progressObserver.observe(row, { attributeFilter: ['data-progress-value'] })
}
