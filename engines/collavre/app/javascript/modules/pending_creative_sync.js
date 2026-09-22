export function hasPendingCreativeSaves(element) {
  return !!element.querySelector('.creative-tree[data-save-state]')
}

export function applyPendingCreativeSyncData(element) {
  if (hasPendingCreativeSaves(element)) return
  // After editor closes, apply any sync data that was deferred
  const pendingRows = element.querySelectorAll('creative-tree-row[data-pending-sync-data]')
  if (pendingRows.length === 0) return

  // Dynamic import to avoid circular dependency
  return import('../creatives/tree_renderer').then(({ applyRowProperties }) => {
    pendingRows.forEach(row => {
      try {
        const data = JSON.parse(row.dataset.pendingSyncData)
        applyRowProperties(row, data)
      } catch (e) {
        console.warn('[TreeController] Failed to apply pending sync data', e)
      }
      delete row.dataset.pendingSyncData
    })
  })
}
