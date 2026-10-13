export function invalidateCreativeTree(detail = {}) {
  document.dispatchEvent(new CustomEvent('creative-sync:refetch'))
  document.dispatchEvent(new CustomEvent('workspace-tree:invalidate', { detail }))
}

// Broadcasts contain raw progress; refetch with the active filter instead.
export function refreshFilteredProgress() {
  if (hasActiveTagFilter()) {
    invalidateCreativeTree()
  }
}


function hasActiveTagFilter() {
  const tree = document.querySelector('[data-creatives--tree-url-value]')
  if (!tree) return document.querySelector('creative-tree-row[data-display-progress]') != null
  const params = new URL(tree.getAttribute('data-creatives--tree-url-value'), window.location.origin).searchParams
  return [...params.getAll('tags[]'), ...params.getAll('tags')].some(value => value.trim() !== '')
}
