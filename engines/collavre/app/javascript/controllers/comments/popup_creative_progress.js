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
