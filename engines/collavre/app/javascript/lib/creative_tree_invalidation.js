export function invalidateCreativeTree(detail = {}) {
  document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
  document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', { detail }))
}

// Broadcasts contain raw progress; refetch with the active filter instead.
export function refreshFilteredProgress() {
  if (document.querySelector('creative-tree-row[data-display-progress]')) {
    invalidateCreativeTree()
  }
}
